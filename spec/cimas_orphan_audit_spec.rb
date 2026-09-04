# Offline tests for bin/cimas-orphan-audit. Only the paths that reach no repo
# are exercised here; the orphan decision itself is pinned in
# spec/cimas_config_spec.rb, and the live sweep needs 98 repos and a `gh`
# login, so it stays out of the suite — the same split
# spec/check_data_pages_spec.rb makes.
require "English"

RSpec.describe "bin/cimas-orphan-audit" do
  bin = File.expand_path("../bin/cimas-orphan-audit", __dir__)

  def run(*args)
    output = `#{args.unshift(File.expand_path('../bin/cimas-orphan-audit', __dir__))
                   .map { |a| "'#{a}'" }.join(' ')} 2>&1`
    [output, $CHILD_STATUS.exitstatus]
  end

  it "is executable" do
    expect(File.executable?(bin)).to be true
  end

  it "prints its usage and exits 0" do
    output, status = run("--help")
    expect(status).to eq(0)
    expect(output).to include("Usage: bin/cimas-orphan-audit")
  end

  it "lists every repo cimas.yml knows and exits 0" do
    output, status = run("--list")
    expect(status).to eq(0)
    expect(output.lines.map(&:strip)).to include("relaton-models", "relaton-data-iso")
  end

  it "rejects an unknown repo before it reaches the network" do
    output, status = run("no-such-repo")
    expect(status).to eq(2)
    expect(output).to include("unknown repo or group")
  end

  it "refuses --show without exactly one repo and one target" do
    output, status = run("--show", "relaton-models")
    expect(status).to eq(2)
    expect(output).to include("--show needs")
  end
end
