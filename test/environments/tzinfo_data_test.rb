# frozen_string_literal: true

require "test_helper"

# Environment contract for the default environment (current tzinfo-data).
# Invoked directly by the baseline CI step, never loaded by the suite. The
# default environment is the one place all three capabilities are guaranteed,
# so this is the tripwire for the capability-gated loader: a probe that
# rotted to false would unload its capability file silently everywhere else.
# See docs/tz-database-axis.md.
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
