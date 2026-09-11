# Windows is the slowest runner in every OS matrix here, so a run ends when its
# last Windows job ends. GitHub creates matrix jobs in list order, and under
# `max-parallel` the jobs at the end of the list wait for a free slot. A Windows
# job at the end therefore starts last and finishes last, and the whole run
# waits for it. These specs keep Windows at the front of each matrix.
require "json"
require "open3"

RSpec.describe "OS order in the workflow matrices" do
  workflows = File.expand_path("../.github/workflows", __dir__)

  describe ".github/workflows/rake-monorepo.yml" do
    step = YAML.load_file(File.join(workflows, "rake-monorepo.yml"))
      .dig("jobs", "prepare", "steps")
      .find { |s| s["id"] == "combined_matrix" }
    script = step.fetch("run")

    # The matrix is built by jq inside a shell script, so run that jq program
    # for real. A structural check of the YAML cannot see the job order.
    combine = script[/\| jq --argjson gems "\$gems_array" --arg allow "\$allow" '([^']*)'/, 1] or
      raise "combined-matrix jq program not found"
    default_ruby = script[/default_ruby_version=\$\(echo "\$combined" \| jq -r '([^']*)'\)/, 1] or
      raise "default-ruby jq program not found"

    # The shape of metanorma/ci's ruby-matrix.json, whose OS list is
    # alphabetical: Windows is last.
    ruby_matrix = {
      "ruby" => [
        { "version" => "3.3", "experimental" => false },
        { "version" => "3.4", "experimental" => false },
        { "version" => "4.0", "experimental" => true },
      ],
      "os" => %w[macos-latest ubuntu-latest windows-latest],
    }
    gems = %w[relaton-cli relaton-foo]

    def jq(program, input, *args)
      out, err, status = Open3.capture3("jq", *args, program, stdin_data: input)
      raise "jq failed: #{err}" unless status.success?

      out
    end

    let(:combined) do
      jq(combine, ruby_matrix.to_json, "--argjson", "gems", gems.to_json, "--arg", "allow", "")
    end
    let(:jobs) { JSON.parse(combined).fetch("include") }
    let(:labels) { jobs.map { |j| [j["gem"], j.dig("ruby", "version"), j["os"]] } }

    it "puts every Windows job before the first job on another OS" do
      oses = jobs.map { |j| j["os"] }
      windows = oses.count("windows-latest")

      expect(windows).to eq(gems.size * 3)
      expect(oses.first(windows)).to all(eq("windows-latest"))
    end

    it "keeps every gem × ruby × os job" do
      expect(labels).to match_array(
        gems.product(%w[3.3 3.4 4.0], ruby_matrix["os"]),
      )
    end

    it "keeps the gem × ruby order inside each OS group" do
      # A stable sort: moving Windows forward must not shuffle the rest.
      expect(labels.select { |l| l[2] == "windows-latest" })
        .to eq(gems.product(%w[3.3 3.4 4.0], ["windows-latest"]))
      expect(labels.reject { |l| l[2] == "windows-latest" })
        .to eq(gems.product(%w[3.3 3.4 4.0], %w[macos-latest ubuntu-latest]))
    end

    it "keeps the default Ruby at the first non-experimental version" do
      # The codecov upload matches on this value.
      expect(jq(default_ruby, combined, "-r").strip).to eq("3.3")
    end
  end

  describe ".github/workflows/make.yml" do
    oses = YAML.load_file(File.join(workflows, "make.yml"))
      .dig("jobs", "make", "strategy", "matrix", "os")

    it "lists Windows first" do
      expect(oses.first).to eq("windows-latest")
    end

    it "keeps the three OSes" do
      expect(oses).to contain_exactly("ubuntu-latest", "windows-latest", "macos-latest")
    end
  end
end
