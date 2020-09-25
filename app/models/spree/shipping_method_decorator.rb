Spree::ShippingMethod.class_eval do
  scope :price_sacks, -> { joins(:calculator).where('spree_calculators.type': "Spree::Calculator::Shipping::PriceSack") }
	
	def is_price_sack?
		calculator.type == 'Spree::Calculator::Shipping::PriceSack'
	end
		
  # Some shipping methods are only meant to be set via backend
  def frontend?
    self.display_on != "back_end" && !none?
  end

  # Some shipping methods should not be displayed at all
  def none?
    self.display_on == "none"
  end

  def both?
    self.display_on == 'both'
  end

  # Only should shipping methods that need to be displayed
  def available_to_display(display_filter)
    (frontend? && display_filter == Spree::ShippingMethod::DISPLAY_ON_FRONT_END) ||
    ((!frontend? || both?) && display_filter == Spree::ShippingMethod::DISPLAY_ON_BACK_END)
  end

end
