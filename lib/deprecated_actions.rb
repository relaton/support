# frozen_string_literal: true

require "yaml"

# Reads `.github/deprecated-actions.yml`, the hand-written record of which
# GitHub Actions majors are deprecated upstream.
#
# Two things consume it:
#
#   bin/actions-audit                -> the quarterly sweep, which files an
#                                       issue per deprecated pin it finds.
#   spec/deprecated_actions_spec.rb  -> the pull-request gate, which fails the
#                                       build on a deprecated pin about three
#                                       months before the cron would say so.
#
# The list is hand-curated because GitHub publishes no stable machine-readable
# deprecation feed for action majors. A new deprecation is a new row, never an
# edit to the code — the same shape `cimas-config/orphan-allowlist.yml` has.
#
# The schema matches `metanorma/ci`'s `.github/deprecated-actions.yml` exactly,
# so the two lists can be diffed against each other as deprecations are
# announced:
#
#   action: <owner>/<action>          required
#   deprecated_versions: [v1, ...]    required, strings
#   current_version: <ref>            optional, what to move to
#   notes: "..."                      optional, why
#   reference: https://...            optional, the announcement
#
# This covers only a version that upstream still publishes and has marked
# deprecated. An action that was *deleted* — the case that motivated
# relaton/support#64, where `plantuml-setup-action` sat dead in make.yml for
# about eleven months — can never appear on a list like this. bin/actions-audit
# catches that class separately, by asking GitHub whether the pin still
# resolves.
class DeprecatedActions
  Error = Class.new(StandardError)

  DEFAULT_PATH =
    File.expand_path("../.github/deprecated-actions.yml", __dir__).freeze

  attr_reader :entries

  def self.load(path = DEFAULT_PATH)
    raise Error, "no deprecation list at #{path}" unless File.exist?(path)

    data = YAML.safe_load_file(path)
    raise Error, "#{path} does not hold a list of rows" unless data.is_a?(Array)

    new(data)
  end

  def initialize(entries)
    @entries = entries
  end

  def entry_for(action)
    entries.find { |entry| entry["action"] == action }
  end

  def deprecated?(pin)
    !finding_for(pin).nil?
  end

  # The row that condemns this pin, so the report can quote its notes and its
  # reference. nil when the pin is fine, or when no row names the action.
  def finding_for(pin)
    entry = entry_for(pin.action)
    return nil unless entry

    Array(entry["deprecated_versions"]).include?(pin.ref) ? entry : nil
  end
end
