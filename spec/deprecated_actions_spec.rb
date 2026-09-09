# The curated half of the actions audit, and the gate it puts on this repo.
#
# `.github/deprecated-actions.yml` is a hand-written record of which GitHub
# Actions majors are deprecated. It is the only half of the audit that works
# offline, so it is the half that can run on every pull request — the same
# move spec/workflow_permissions_spec.rb makes, and for the same reason: a rule
# nobody runs is a rule that decays.
#
# The last example is the gate. It fails the build when a workflow in this repo
# pins a major the list calls deprecated, which is three months earlier than the
# quarterly cron would say so.
#
# The resolvability half — does `<owner>/<action>@<ref>` still exist upstream —
# needs the network and lives only in bin/actions-audit. This suite is offline
# by design (no webmock, no VCR), the same split spec/cimas_orphan_audit_spec.rb
# and spec/check_data_pages_spec.rb make.
require "deprecated_actions"
require "workflow_pins"

RSpec.describe DeprecatedActions do
  let(:list) { described_class.load }

  describe "the shipped file" do
    it "names an action as owner/name" do
      malformed = list.entries.map { |e| e["action"] }
                      .reject { |a| a.to_s.match?(%r{\A[\w.-]+(/[\w.-]+)+\z}) }
      expect(malformed).to be_empty,
                           "these rows do not name an action: #{malformed.inspect}"
    end

    it "gives every row at least one deprecated version" do
      empty = list.entries.select { |e| Array(e["deprecated_versions"]).empty? }
                  .map { |e| e["action"] }
      expect(empty).to be_empty,
                       "a row with no version flags nothing: #{empty.join(', ')}"
    end

    # An unquoted `v4` is a string, but an unquoted `4` is an Integer and would
    # never equal the `"v4"` a workflow pins. The row would then be silently
    # dead, which is the class of failure this whole file guards.
    it "writes every version as a string" do
      wrong = list.entries.flat_map do |entry|
        Array(entry["deprecated_versions"]).reject { |v| v.is_a?(String) }
      end
      expect(wrong).to be_empty,
                       "these versions are not strings: #{wrong.inspect}"
    end

    it "names each action once" do
      actions = list.entries.map { |e| e["action"] }
      expect(actions).to eq(actions.uniq)
    end

    # A row telling a reader to move to a version the same row deprecates is a
    # transcription slip, and it sends the fix in a circle.
    it "never suggests a version it also deprecates" do
      contradictory = list.entries.select do |entry|
        entry["current_version"] &&
          Array(entry["deprecated_versions"]).include?(entry["current_version"])
      end.map { |e| e["action"] }
      expect(contradictory).to be_empty,
                               "current_version is also deprecated for: " \
                               "#{contradictory.join(', ')}"
    end

    it "gives every reference an https URL" do
      bad = list.entries.map { |e| e["reference"] }.compact
                .reject { |url| url.start_with?("https://") }
      expect(bad).to be_empty, "not https: #{bad.inspect}"
    end
  end

  # Proved against a fixture rather than against the shipped tree, so the gate
  # below can stay green without this file losing its teeth.
  describe "#deprecated?" do
    let(:list) { described_class.new([{ "action" => "actions/checkout", "deprecated_versions" => %w[v1 v2 v3] }]) }

    def pin(action, ref)
      WorkflowPins::Pin.new(file: "f.yml", line: 1, action: action, ref: ref)
    end

    it "flags a pinned deprecated major" do
      expect(list.deprecated?(pin("actions/checkout", "v3"))).to be true
    end

    it "passes a major the row does not list" do
      expect(list.deprecated?(pin("actions/checkout", "v4"))).to be false
    end

    it "passes an action with no row" do
      expect(list.deprecated?(pin("ruby/setup-ruby", "v1"))).to be false
    end

    it "returns the row so the report can quote it" do
      expect(list.entry_for("actions/checkout")["deprecated_versions"]).to eq(%w[v1 v2 v3])
    end
  end

  # The gate.
  it "finds no deprecated pin in this repo's workflows" do
    pins = WorkflowPins.scan
    # Stated here rather than left to spec/workflow_pins_spec.rb: an extraction
    # that returned nothing would satisfy the emptiness check below and report
    # a clean tree, which is the exact failure this gate exists to catch.
    expect(pins).not_to be_empty

    found = pins.select { |pin| list.deprecated?(pin) }
    expect(found).to be_empty,
                     "deprecated pins:\n" +
                     found.map { |p| "  #{p.file}:#{p.line}  #{p}" }.join("\n")
  end
end
