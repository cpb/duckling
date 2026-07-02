# frozen_string_literal: true

require_relative "duckling/version"
require_relative "duckling/duckling"
require_relative "duckling/entities"

module Duckling
  # Duckling.parse(text, locale: "en", dims: ["time"], reference_time: nil, with_latent: false)
  #
  # Wraps the fast native Duckling::Native.parse (which returns a raw,
  # symbol-keyed, externally-tagged Hash) and builds the Data-based value
  # objects in lib/duckling/entities.rb from it via case/in pattern matching.
  def self.parse(text, **opts)
    Native.parse(text, **opts).map { |h| Entities.build(h) }
  end
end
