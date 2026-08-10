# frozen_string_literal: true

require "test_helper"

# Environment contract for the links-less zoneinfo environment
# (bin/build-linkless-zoneinfo + DUCKLING_ZONEINFO_DIR): invoked directly by
# the CI step that builds the stripped tree, never loaded by the suite — see
# "The tz-database axis" in AGENTS.md. Run it by hand against a built tree:
#
#   bin/build-linkless-zoneinfo /tmp/linkless-zoneinfo
#   DUCKLING_ZONEINFO_DIR=/tmp/linkless-zoneinfo bundle exec ruby -Ilib -Itest test/environments/linkless_zoneinfo_test.rb
#
# The build script already hard-fails if US/Eastern survives the strip; this
# contract is the second, independent check, reached through Duckling.parse
# at the level a consumer observes. It also pins the remedy wording for a
# *real* backward-compat name — the every-environment remedy test
# (DucklingTest#test_reference_zone_error_offers_the_backward_compat_remedy_only_where_relevant)
# passes a typo'd one.
class LinklessZoneinfoTest < Minitest::Test
  def test_the_environment_has_no_backward_compat_links
    refute TZCapabilities.supports?(:backward_compat_links),
      "expected a links-less datasource, got #{TZCapabilities.datasource_description}. " \
      "If DUCKLING_ZONEINFO_DIR points at a stripped tree, the strip stopped working."
  end

  # The strip deletes by default against a hand-transcribed keep-list, and the
  # build script's own postcondition (US/Eastern is gone) can only catch
  # *under*-stripping. Over-stripping is the likelier drift — a future tzdata
  # or a different base image adds a top-level entry a real links-less host
  # keeps, this deletes it, and the environment quietly models something
  # poorer than it claims while the capability gate absorbs the difference.
  #
  # The transcription is what makes the keep-list trustworthy, and the
  # identifier count is what the transcription was recorded against (a
  # Debian-family container with tzdata and no tzdata-legacy: 497). A range
  # rather than that exact number, since real tzdata releases add and retire
  # zones — wide enough not to be brittle, narrow enough that deleting a
  # top-level tree or restoring the ~100 links both land outside it.
  def test_the_environment_keeps_the_rest_of_the_database
    count = TZInfo::Timezone.all_identifiers.size

    assert_operator count, :>, 400,
      "expected a links-less tree to keep the canonical zones (~497), got #{count} — " \
      "the strip is deleting entries a stock host keeps"
    assert_operator count, :<, 560,
      "expected the backward-compat names to be gone (~497), got #{count} — " \
      "the strip is leaving entries a stock host does not have"
  end

  def test_us_eastern_raises_naming_both_remedies
    error = assert_raises(ArgumentError) do
      Duckling.parse("in 3 hours", locale: "en", dims: ["time"], reference_zone: "US/Eastern")
    end

    assert_includes error.message, "tzinfo-data",
      "expected the gem remedy for the missing backward-compat links, got: #{error.message.inspect}"
    assert_includes error.message, "tzdata-legacy",
      "expected the system-package remedy for the missing backward-compat links, got: #{error.message.inspect}"
  end
end
