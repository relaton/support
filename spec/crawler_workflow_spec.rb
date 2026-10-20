# The shared Crawler workflow writes provenance.json and tombstones.yaml for
# every data repo. The logic lives inline in the workflow (the data repo
# checkout has no support scripts), so this spec extracts the heredoc and runs
# it against a throwaway git repo.
require "json"
require "open3"
require "tmpdir"
require "yaml"

RSpec.describe "crawler workflow: provenance and tombstones" do
  WORKFLOW = File.expand_path("../.github/workflows/crawler.yml", __dir__)

  def ruby_script
    workflow = YAML.safe_load_file(WORKFLOW, aliases: true)
    step = workflow.dig("jobs", "crawl", "steps")
                   .find { |s| s["name"] == "Diff data" }
    match = step["run"].match(/ruby <<'RUBY'\n(.*?)\nRUBY/m)
    raise "provenance heredoc not found in the Diff data step" unless match

    match[1]
  end

  def with_repo
    Dir.mktmpdir("crawl-spec-") do |dir|
      git(dir, "init", "-q")
      git(dir, "config", "user.email", "spec@example.test")
      git(dir, "config", "user.name", "Spec")
      FileUtils.mkdir_p(File.join(dir, "data"))
      yield dir
    end
  end

  def git(dir, *args)
    _out, err, status = Open3.capture3("git", *args, chdir: dir)
    raise "git #{args.join(' ')}: #{err}" unless status.success?
  end

  def run_script(dir)
    script = File.join(dir, "provenance.rb")
    File.write(script, ruby_script)
    env = {
      "GITHUB_REPOSITORY" => "relaton/relaton-data-spec",
      "GITHUB_WORKFLOW" => "Crawler",
      "GITHUB_RUN_ID" => "4242",
      "GITHUB_RUN_ATTEMPT" => "1",
      "GITHUB_SHA" => "cafe1234",
      "CRAWLER_COMMAND" => "bundle exec ruby crawler.rb",
    }
    _out, err, status = Open3.capture3(env, "ruby", script, chdir: dir)
    raise "provenance script failed: #{err}" unless status.success?
  end

  def commit_record(dir, name, id)
    File.write(File.join(dir, "data", name), <<~YAML)
      ---
      id: #{id}
      docidentifier:
      - content: #{id} 1
        type: SPEC
        primary: true
    YAML
    git(dir, "add", "data")
    git(dir, "commit", "-qm", "add #{name}")
  end

  it "records the revision, run and time of the crawl" do
    with_repo do |dir|
      commit_record(dir, "a.yaml", "SPEC1")
      File.delete(File.join(dir, "data", "a.yaml"))

      run_script(dir)

      provenance = JSON.parse(File.read(File.join(dir, "provenance.json")))
      expect(provenance).to include(
        "repository" => "relaton/relaton-data-spec",
        "workflow" => "Crawler",
        "run_id" => "4242",
        "source_revision" => "cafe1234",
        "crawler" => "bundle exec ruby crawler.rb",
      )
      expect(provenance["crawled_at"]).to match(/\A\d{4}-\d{2}-\d{2}T/)
    end
  end

  it "marks a document the crawl no longer produces" do
    with_repo do |dir|
      commit_record(dir, "a.yaml", "SPEC1")
      File.delete(File.join(dir, "data", "a.yaml"))

      run_script(dir)

      tombstones = YAML.safe_load_file(File.join(dir, "tombstones.yaml"))
      expect(tombstones).to contain_exactly(
        a_hash_including("id" => "SPEC1", "file" => "data/a.yaml", "run_id" => "4242"),
      )
    end
  end

  it "keeps an existing tombstone when the document stays gone" do
    with_repo do |dir|
      commit_record(dir, "a.yaml", "SPEC1")
      commit_record(dir, "b.yaml", "SPEC2")
      File.delete(File.join(dir, "data", "a.yaml"))

      run_script(dir)
      # The tombstone is committed as the crawler workflow does before its
      # next run deletes another file.
      git(dir, "add", "data/a.yaml", "tombstones.yaml")
      git(dir, "commit", "-qm", "tombstone")
      File.delete(File.join(dir, "data", "b.yaml"))

      run_script(dir)

      ids = YAML.safe_load_file(File.join(dir, "tombstones.yaml")).map { |t| t["id"] }
      expect(ids).to contain_exactly("SPEC1", "SPEC2")
    end
  end

  it "drops a tombstone when the document is published again" do
    with_repo do |dir|
      commit_record(dir, "a.yaml", "SPEC1")
      File.delete(File.join(dir, "data", "a.yaml"))
      run_script(dir)
      git(dir, "add", "data/a.yaml", "tombstones.yaml")
      git(dir, "commit", "-qm", "tombstone")

      commit_record(dir, "a.yaml", "SPEC1")
      run_script(dir)

      expect(File.exist?(File.join(dir, "tombstones.yaml"))).to be false
    end
  end
end
