# Turns the crate's rules and variants into the pipeline's unit of work: a
# slice. One slice is one TimeForm variant plus the rules that construct it,
# or the modifier rules, or one dependency dimension.
#
# The ownership rule is the load-bearing part. 33 rules construct more than
# one variant, so without a single-owner tiebreak several slices would claim
# the same rule — which is exactly the file conflict the one-file-per-slice
# convention exists to prevent.

require_relative "config"
require_relative "crate"

module Plan
  Slice = Struct.new(:key, :slug, :wave, :kind, :excerpt, :resolver_refs, :rules) do
    def modifiers? = kind == :modifiers

    def dimension? = kind == :dimension

    def time_form? = kind == :time_form

    def label = if modifiers?
                  "modifier and absorption rules"
                else
                  (dimension? ? "#{key} dimension" : "TimeForm::#{key}")
                end
  end

  class SliceSet
    include Enumerable

    WAVE_RANK = {"A" => 1, "B" => 2, "C" => 3}.freeze

    def initialize(crate = Crate.new, config = Plan.config)
      @crate = crate
      @config = config
    end

    def each(&) = slices.each(&)

    def [](key) = slices.find { |s| s.key == key }

    def slices
      @slices ||= begin
        owned = ownership
        variants = @crate.time_form_variants
        list = @config.all_variants.map do |v|
          Slice.new(key: v, slug: slugify(v), wave: @config.wave_of(v), kind: :time_form,
            excerpt: variants.fetch(v), resolver_refs: @crate.resolver_references(v),
            rules: owned.fetch(v, []))
        end
        list << Slice.new(key: "Modifiers", slug: "modifiers", wave: "A", kind: :modifiers,
          excerpt: nil, resolver_refs: 0, rules: owned.fetch("Modifiers", []))
        list + @config.dependency_dimensions.map do |d|
          Slice.new(key: d, slug: d, wave: "A", kind: :dimension, excerpt: nil, resolver_refs: 0,
            rules: @crate.rules(@crate.dimension_en(d)))
        end
      end
    end

    # A rule is owned by the highest-wave variant it constructs.
    # "tomorrow morning" builds Composed(Tomorrow, PartOfDay), so it belongs
    # to Wave C's Composed slice, not Wave A's Tomorrow.
    def ownership
      @ownership ||= @crate.rules.each_with_object(Hash.new { |h, k| h[k] = [] }) do |rule, acc|
        acc[owner_of(rule)] << rule
      end
    end

    def owner_of(rule)
      return "Modifiers" if rule.builds.empty?
      rule.builds.max_by { |v| WAVE_RANK.fetch(@config.wave_of(v), 0) }
    end

    private

    def slugify(name)
      name.gsub(/([a-z0-9])([A-Z])/, '\1_\2').gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2').downcase
    end
  end
end
