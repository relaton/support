# Guards cimas-config/gh-actions/data-eu/crawler.yml, the one per-flavor crawler
# caller in the fleet.
#
# relaton-data-eu's crawler.rb takes `full` (full crawl with prune) or `updates`
# (update run); with no argument it picks the run itself. The repo owner wants a
# "Run workflow" checkbox for the full crawl. The shared gh-actions/data/crawler.yml
# cannot carry it: the other data repos' crawler.rb files do not take `full`.
#
# So this template is the shared one plus exactly two differences. Everything
# else must stay in step with gh-actions/data/crawler.yml, or a fleet-wide fix
# there (a cron move, a permissions change) silently skips relaton-data-eu.
RSpec.describe "cimas-config/gh-actions/data-eu/crawler.yml (the EU Crawler caller)" do
  repo_root = File.expand_path("..", __dir__)
  eu_path = File.join(repo_root, "cimas-config/gh-actions/data-eu/crawler.yml")
  shared_path = File.join(repo_root, "cimas-config/gh-actions/data/crawler.yml")

  # Loaded inside the examples, so a missing template fails as red examples
  # rather than aborting the file at load time.
  eu = -> { YAML.safe_load_file(eu_path) }
  shared = -> { YAML.safe_load_file(shared_path) }
  # Psych reads the unquoted `on:` key as YAML 1.1 boolean true.
  inputs = ->(doc) { doc.fetch(true).fetch("workflow_dispatch").fetch("inputs") }
  with = ->(doc) { doc.fetch("jobs").fetch("crawl").fetch("with") }
  cimas = -> { YAML.safe_load_file(File.join(repo_root, "cimas-config/cimas.yml")) }

  it "has a boolean `full` input that is off by default" do
    full = inputs.call(eu.call).fetch("full")

    expect(full).to include("type" => "boolean", "required" => false, "default" => false)
  end

  it "passes `full` to crawler.rb when the box is ticked, else the free-text args" do
    # On a scheduled run `inputs.full` is empty, so args is '' and crawler.rb
    # picks the run itself (full on UTC day 1 or with no cellar-since.txt).
    expect(with.call(eu.call).fetch("args"))
      .to eq("${{ inputs.full && 'full' || github.event.inputs.args }}")
  end

  it "differs from the shared crawler template only by the `full` input and `args`" do
    doc = eu.call
    inputs.call(doc).delete("full")
    with.call(doc).delete("args")
    base = shared.call
    with.call(base).delete("args")

    expect(doc).to eq(base)
  end

  it "keeps the shared template's `name:`, which deploy.yml's workflow_run matches" do
    expect(eu.call.fetch("name")).to eq(shared.call.fetch("name"))
  end

  it "is the crawler.yml that cimas.yml syncs into relaton-data-eu, and only there" do
    repos = cimas.call.fetch("repositories")
    users = repos.select do |_, r|
      (r&.fetch("files", nil) || {}).value?("gh-actions/data-eu/crawler.yml")
    end.keys

    expect(users).to eq(["relaton-data-eu"])
    expect(repos.fetch("relaton-data-eu").fetch("files").fetch(".github/workflows/crawler.yml"))
      .to eq("gh-actions/data-eu/crawler.yml")
  end

  it "puts relaton-data-eu in the `data` group" do
    expect(cimas.call.fetch("groups").fetch("data")).to include("relaton-data-eu")
  end
end
