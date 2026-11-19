# .github/workflows/rake.yml runs the tests-passed cascade itself, with a job
# that holds `contents: write`.
#
# metanorma/ci decc7b1 dropped generic-rake's job-level `contents: write` from
# its tests-passed job, so that job runs under the file's `contents: read`. A
# caller without a pat_token then handed the dispatch a read-only GITHUB_TOKEN,
# and every push to main ended in "Resource not accessible by integration"
# (relaton/loc_marc). A caller cannot raise a grant that a called workflow
# lowers, so the dispatch has to move to a job that this file controls.
#
# Do not gate the cascade on a PAT: a repository_dispatch sent with the
# GITHUB_TOKEN does start workflow runs, and `do-release` on a v* tag depends
# on that for every caller without a PAT.
RSpec.describe "rake.yml tests-passed cascade" do
  repo_root = File.expand_path("..", __dir__)
  workflow = YAML.safe_load_file(File.join(repo_root, ".github/workflows/rake.yml"))
  jobs = workflow.fetch("jobs")

  describe "the rake job" do
    let(:job) { jobs.fetch("rake") }

    it "turns off generic-rake's read-only cascade" do
      expect(job.dig("with", "cascade")).to be(false)
    end

    it "still forwards the token fallback that generic-rake uses for checkout" do
      expect(job.dig("secrets", "pat_token"))
        .to eq("${{ secrets.pat_token || github.token }}")
    end
  end

  describe "the tests-passed job" do
    let(:job) { jobs.fetch("tests-passed") }
    let(:steps) { job.fetch("steps") }

    it "runs after rake, and on non-PR runs only" do
      expect(job["needs"]).to eq("rake")
      expect(job["if"]).to eq("github.event_name != 'pull_request'")
    end

    it "holds the write grant that repository_dispatch needs" do
      expect(job["permissions"]).to eq("contents" => "write")
    end

    it "dispatches the tests-passed event, and the release event on v* tags only" do
      expect(steps.map { |s| s.dig("with", "event-type") })
        .to eq(["${{ inputs.tests-passed-event }}", "${{ inputs.release-event }}"])
      expect(steps.map { |s| s["if"] })
        .to eq([nil, "startsWith(github.ref, 'refs/tags/v')"])
    end

    it "uses the PAT when there is one, and the GITHUB_TOKEN when not" do
      expect(steps.map { |s| s.dig("with", "token") }.uniq)
        .to eq(["${{ secrets.pat_token || github.token }}"])
    end
  end
end
