require 'shopify_api'

module Spree
  module Stock
    module EstimatorDecorator
      def shipping_rates(package, shipping_method_filter = ShippingMethod::DISPLAY_ON_FRONT_END)
        # Only use easypost on the FrontEnd if the flag is set and the package
        # flag allows for it to be used. Otherwise use the default spree methods.
        # This allows for faster load times on the front end if we dont want to do dyanmic shipping
        puts "use easypost?  #{use_easypost_to_calculate_rate?(package, shipping_method_filter)}"

        if use_easypost_to_calculate_rate?(package, shipping_method_filter)
          shipment = package.easypost_shipment
          rates = shipment.rates.sort_by { |r| r.rate.to_i }

          vendor_id = package.stock_location.try(:vendor_id)

          if vendor_id.present?
            #add price sacks to easypost rates
            shipping_rates = calculate_price_sacks(vendor_id, package, shipping_method_filter)
            shipping_rates << shopify_rates(package, vendor_id)
            shipping_rates = shipping_rates.flatten
          else
            shipping_rates = []
          end
          
          if rates.any?
            rates.each do |rate|
              # See if we can find the shipping method otherwise create it
              shipping_method = find_or_create_shipping_method(rate, vendor_id)
              next unless shipping_method.present?
              # Get the calculator to see if we want to use easypost rate
              calculator = shipping_method.calculator
              # Create the easypost rate
              spree_rate = Spree::ShippingRate.new(
                cost: calculator == Spree::Calculator::Shipping::EasypostRate ? calculator.compute(package) : rate.rate  ,
                easy_post_shipment_id: rate.shipment_id,
                easy_post_rate_id: rate.id,
                shipping_method: shipping_method
              )

              # Save the rates that we want to show the customer
              shipping_rates << spree_rate if shipping_method.available_to_display(shipping_method_filter)
            end

            # Sets cheapest rate to be selected by default
            if shipping_rates.any?
              shipping_rates.min_by(&:cost).selected = true
            end
            shipping_rates
          else
            shipping_rates
          end
        else
          rates = calculate_shipping_rates(package, shipping_method_filter)
          choose_default_shipping_rate(rates)
          sort_shipping_rates(rates)
        end
      end

      private

      def use_easypost_to_calculate_rate?(package, shipping_method_filter)
        package.use_easypost? && package.weight > 0 &&
        (ShippingMethod::DISPLAY_ON_BACK_END == shipping_method_filter ||
        is_shipping_rate_dynamic_on_front_end?(shipping_method_filter))
      end

      def is_shipping_rate_dynamic_on_front_end?(shipping_method_filter)
        Spree::Config[:use_easypost_on_frontend] &&
        (ShippingMethod::DISPLAY_ON_FRONT_END == shipping_method_filter)
      end

      # Cartons require shipping methods to be present, This will lookup a
      # Shipping method based on the admin(internal)_name. This is not user facing
      # and should not be changed in the admin.
      def find_or_create_shipping_method(rate, vendor_id)
        method_name = "#{ rate.carrier } #{ rate.service }"
        puts "here i am: #{vendor_id} #{method_name}"
        #TODO figure out if easypost shipping rates shoudl be generic (yes?) or per vendor
        if vendor_id.present?
          vendor = Spree::Vendor.find_by(id: vendor_id)
          vendor.present? ? vendor.shipping_methods.find_by(admin_name: method_name) : nil
        else
          Spree::ShippingMethod.find_or_create_by(admin_name: method_name) do |r|
            r.name = method_name
            r.display_on = 'back_end'
            r.code = rate.service
            r.calculator = Spree::Calculator::Shipping::FlatRate.create
            r.shipping_categories = [Spree::ShippingCategory.first]
          end
        end
      end

      def price_sacks(vendor_id, package, display_filter)
        vendor = Spree::Vendor.find_by(id: vendor_id)

        vendor.shipping_methods.price_sacks.select do |ship_method|
          calculator = ship_method.calculator

          ship_method.available_to_display?(display_filter) &&
            ship_method.include?(order.ship_address) &&
            calculator.available?(package) &&
            (calculator.preferences[:currency].blank? ||
             calculator.preferences[:currency] == currency)
        end
      end

      def calculate_price_sacks(vendor_id, package, display_filter)
        price_sacks(vendor_id, package, display_filter).map do |shipping_method|
          cost = shipping_method.calculator.compute(package)

          #don't display price sacks with easypost unless they are free
          next if (cost.blank? || cost > 0)

          shipping_method.shipping_rates.new(
            cost: gross_amount(cost, taxation_options_for(shipping_method)),
            tax_rate: first_tax_rate_for(shipping_method.tax_category)
          )
        end.compact
      end

      def shopify_rates(package, vendor_id)
        shopify_vendor = Spree::ShopifyVendor.find_by(spree_vendor_id: vendor_id)

        session = ShopifyAPI::Session.new(
          domain: shopify_vendor.shopify_domain, 
          token: shopify_vendor.shopify_token, 
          api_version: ENV['SHOPIFY_API_VERSION'], 
          extra: {}
        )

        ShopifyAPI::Base.activate_session(session)
        shipping_address = package.order.shipping_address

        shopify_checkout = ShopifyAPI::Checkout.create(
          email: package.order.user.try(:email),
          line_items: shopify_line_items(package),
          shipping_address: {
            first_name: shipping_address.firstname,
            last_name: shipping_address.lastname,
            address1: shipping_address.address1,
            address2: shipping_address.address2,
            city: shipping_address.city,
            province_code: shipping_address.state_abbr,
            country_code: shipping_address.country_iso3,
            phone: shipping_address.phone,
            zip: shipping_address.zipcode
          }
        )

        rates = shopify_shipping_rates(shopify_checkout.shipping_rates, vendor_id)
        ShopifyAPI::Base.clear_session
        rates
      end

      def shopify_shipping_rates(rates, vendor_id)
        rates.map do |rate|
          shipping_method = Spree::ShippingMethod.find_or_create_by(admin_name: rate.title, name: rate.title) do |r|
            r.display_on = 'both'
            r.vendor_id = vendor_id
            r.calculator = Spree::Calculator::Shipping::FlatRate.create
            r.shipping_categories = [Spree::ShippingCategory.default]
          end

          tax_rate = Spree::TaxRate.create(
            amount: rate.checkout.total_tax.to_f,
            tax_category: Spree::TaxCategory.shopify
            calculator: Spree::Calculator.first
          )

          binding.pry

          Spree::ShippingRate.new(
            cost: rate.price,
            shipping_method: shipping_method,
            tax_rate: tax_rate
          )
        end
      end

      def shopify_line_items(package)
        package.contents.map do |content|
          {
            variant_id: content.inventory_unit.line_item.variant.shopify_id,
            quantity: content.inventory_unit.quantity
          }
        end
      end
    end
  end
end

Spree::Stock::Estimator.prepend Spree::Stock::EstimatorDecorator
