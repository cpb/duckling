# frozen_string_literal: true

require "test_helper"

# Environment contract for the default environment — current tzinfo-data,
# what the committed Gemfile.lock bundles. Invoked directly by the baseline
# CI step, never loaded by the suite.
#
# The default environment is the one place ALL THREE capabilities are
# guaranteed, which makes this the tripwire for the capability-gated loader
# (see the bottom of test_helper.rb): if a probe or the IANA data it asks
# about ever drifts — say a future tzdata stops modelling Dublin with
# negative DST — the affected capability file would silently stop loading
# everywhere, except that its probe now fails here too, and this contract
# turns red.
class TzinfoDataTest < Minitest::Test
  def test_the_datasource_is_the_tzinfo_data_gem
    assert_instance_of TZInfo::DataSources::RubyDataSource, TZInfo::DataSource.get,
      "expected the tzinfo-data gem's datasource in the default environment, got " \
      "#{TZCapabilities.datasource_description} — did the gem fall out of the bundle?"
  end

  def test_all_capabilities_are_present
    TZCapabilities::CAPABILITIES.each_key do |capability|
      assert TZCapabilities.supports?(capability),
        "expected #{capability} from current tzinfo-data, got #{TZCapabilities.datasource_description}"
    end
  end
end
