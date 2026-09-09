# Offline tests for bin/actions-audit. Only the paths that reach no network are
# exercised here; the deprecation decision itself is pinned in
# spec/deprecated_actions_spec.rb, the extraction in spec/workflow_pins_spec.rb,
# and the resolvability sweep needs a `gh` login, so it stays out of the suite —
# the same split spec/cimas_orphan_audit_spec.rb makes.
require "English"

RSpec.describe "bin/actions-audit" do
  bin = File.expand_path("../bin/actions-audit", __dir__)

  def run(*args)
    output = `#{args.unshift(File.expand_path('../bin/actions-audit', __dir__))
                   .map { |a| "'#{a}'" }.join(' ')} 2>&1`
    [output, $CHILD_STATUS.exitstatus]
  end

  it "is executable" do
    expect(File.executable?(bin)).to be true
  end

  it "prints its usage and exits 0" do
    output, status = run("--help")
    expect(status).to eq(0)
    expect(output).to include("Usage: bin/actions-audit")
  end

  it "lists every pin it extracts and exits 0" do
    output, status = run("--list")
    expect(status).to eq(0)
    expect(output).to include("actions/checkout@v4")
    expect(output).to include(".github/workflows/ci-spec.yml")
  end

  it "reports a clean tree and exits 0" do
    output, status = run("--skip-resolve")
    expect(status).to eq(0)
    expect(output).to include("0 deprecated")
  end

  it "rejects an unknown option before it reaches the network" do
    _output, status = run("--no-such-flag")
    expect(status).to eq(2)
  end

  # Writing to the tracker and promising not to write to it are the two things
  # this script must never be asked to do at once.
  it "refuses --dry-run together with --create-issues" do
    output, status = run("--dry-run", "--create-issues", "--skip-resolve")
    expect(status).to eq(2)
    expect(output).to include("--dry-run")
  end

  it "fails loudly when the deprecation list is missing" do
    output, status = run("--config", "no/such/list.yml", "--skip-resolve")
    expect(status).to eq(2)
    expect(output).to include("no/such/list.yml")
  end

  # The default has to be the safe one. A person running this by hand to see
  # what it says must not find that it opened issues on the tracker.
  it "does not offer to write anything unless asked" do
    output, _status = run("--help")
    expect(output).to include("--create-issues")
    expect(output).to match(/report-only/i)
  end
end
