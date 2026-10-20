# The shared Crawler workflow writes a per-release manifest beside every index
# zip it changes. The logic is inline (the data-repo checkout has no support
# scripts), so this spec extracts the heredoc and runs it on a fixture pair.
require "digest"
require "json"
require "open3"
require "tmpdir"
require "yaml"

RSpec.describe "crawler workflow: per-release manifest" do
  WORKFLOW = File.expand_path("../.github/workflows/crawler.yml", __dir__)

  def ruby_script
    workflow = YAML.safe_load_file(WORKFLOW, aliases: true)
    step = workflow.dig("jobs", "crawl", "steps")
                   .find { |s| s["name"] == "Release manifests" }
    raise "release manifest step not found" unless step
    match = step["run"].match(/ruby <<'RUBY'\n(.*?)\nRUBY/m)
    raise "release manifest heredoc not found" unless match

    match[1]
  end

  it "records the artifact's address, size, row count and crawl revision" do
    Dir.mktmpdir("release-spec-") do |dir|
      File.write(File.join(dir, "index-v2.yaml"), [{ id: 1 }, { id: 2 }, { id: 3 }].to_yaml)
      File.binwrite(File.join(dir, "index-v2.zip"), "zip bytes")
      File.write(File.join(dir, "release.rb"), ruby_script)

      env = {
        "RELEASE_YAML" => "index-v2.yaml",
        "RELEASE_ZIP" => "index-v2.zip",
        "GITHUB_SHA" => "abc123",
        "GITHUB_RUN_ID" => "77",
        "GITHUB_REPOSITORY" => "relaton/relaton-data-spec",
      }
      _out, err, status = Open3.capture3(env, "ruby", "release.rb", chdir: dir)
      expect(status).to be_success, err

      manifest = JSON.parse(File.read(File.join(dir, "index-v2.release.json")))
      expect(manifest).to include(
        "version" => 1,
        "index" => "index-v2",
        "sha256" => Digest::SHA256.hexdigest("zip bytes"),
        "bytes" => 9,
        "count" => 3,
        "source_revision" => "abc123",
        "run_id" => "77",
        "repository" => "relaton/relaton-data-spec",
      )
      expect(manifest["generated"]).to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/)
    end
  end
end
