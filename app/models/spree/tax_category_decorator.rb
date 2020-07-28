Spree::TaxCategory.class_eval do
  def self.shopify
    Spree::TaxCategory.where("name ilike 'shopify'").first
  end
end
