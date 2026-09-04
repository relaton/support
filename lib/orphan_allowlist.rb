require "date"
require "set"
require "yaml"

# Reads `cimas-config/orphan-allowlist.yml`, the record of every Cimas-written
# file in a destination repo that `cimas.yml` no longer maps — and of what was
# decided about it.
#
# One command consumes it:
#
#   bin/cimas-orphan-audit -> #covers? and #stale, which turn the audit into a
#                             gate: a new orphan nobody has judged fails the
#                             run; a judged one is reported and passes.
#
# The disposition says what makes a row go away:
#
#   keep   - the destination repo owns the file. A wave must never delete it.
#            The row retires when that repo drops the two Cimas header lines,
#            which is the only permanent fix, so a `keep` row names a hand-off.
#   delete - the file is dead and a wave may take it. The row retires with the
#            wave.
#   review - nobody has judged it yet. The audit still passes, because the row
#            proves a person wrote the question down, but no wave may run
#            unscoped while one stands.
#
# See relaton/support#65 and spec/orphan_allowlist_spec.rb.
class OrphanAllowlist
  DEFAULT_PATH =
    File.expand_path("../cimas-config/orphan-allowlist.yml", __dir__).freeze

  DISPOSITIONS = %w[keep delete review].freeze

  attr_reader :entries

  # `since:` is an unquoted date, which YAML reads as a Date, so that one class
  # is permitted. Nothing else in the file needs it.
  def self.load(path = DEFAULT_PATH)
    data = YAML.safe_load_file(path, permitted_classes: [Date])
    new(data.fetch("allowed") || [])
  end

  def initialize(entries)
    @entries = entries
  end

  def covers?(repo, path)
    !entry_for(repo, path).nil?
  end

  def entry_for(repo, path)
    entries.find { |e| e["repo"] == repo && e["path"] == path }
  end

  # Rows the audit did not meet. Only a row this run could have met can be
  # stale: a run narrowed to one repo says nothing about the others, and a run
  # narrowed with --only-target says nothing about the other paths.
  def stale(findings, scanned:, paths: nil)
    seen = findings.map { |f| [f.repo, f.path] }.to_set
    in_scope = Array(scanned).to_set
    in_paths = paths && Array(paths).to_set
    entries.select do |entry|
      in_scope.include?(entry["repo"]) &&
        (in_paths.nil? || in_paths.include?(entry["path"])) &&
        !seen.include?([entry["repo"], entry["path"]])
    end
  end
end
