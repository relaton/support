# Guards the Cimas caller template that Cimas syncs into every relaton-data-*
# repo as `.github/workflows/deploy.yml`.
#
# The problem it encodes: the template's `push` trigger cannot fire on crawled
# data. crawler.yml's "Push data" step commits with the default
# actions/checkout GITHUB_TOKEN, and GitHub deliberately raises no workflow
# events for GITHUB_TOKEN pushes. That left the daily cron as the only path from
# crawl to Pages — and it assumed a fixed one-hour gap that scheduled dispatch
# does not honour (11 of relaton-data-iana's last 12 Crawler runs *started* at
# or after 14:58 UTC despite a 14:00 cron, several past 16:00), so the 15:00
# deploy usually indexed the previous day's data.
#
# Ordering is now deterministic via `workflow_run`. The couplings below are all
# silent when broken — nothing goes red in CI, the fleet just quietly stops
# republishing — so they are pinned here.
RSpec.describe "cimas-config/gh-actions/data/deploy.yml" do
  repo_root = File.expand_path("..", __dir__)
  template = ->(name) { YAML.safe_load_file(File.join(repo_root, "cimas-config/gh-actions/data", name)) }

  deploy = template.call("deploy.yml")
  crawler = template.call("crawler.yml")
  # Psych reads the unquoted `on:` key as YAML 1.1 boolean true.
  triggers = deploy.fetch(true)
  workflow_run = triggers["workflow_run"]

  # "0 14 * * *" -> 14
  cron_hour = ->(schedule) { Integer(schedule.fetch(0).fetch("cron").split.fetch(1)) }

  describe "the workflow_run trigger" do
    it "is declared, so a crawler commit reaches Pages the same day" do
      expect(workflow_run).to be_a(Hash)
    end

    it "names the crawler template's own `name:`" do
      # THE load-bearing assertion. `workflows:` matches the triggering
      # workflow's `name:` field, and both files are synced together by Cimas —
      # so renaming crawler.yml's `name:` silently stops the deploy trigger
      # firing in every data repo, with nothing red to notice.
      expect(workflow_run.fetch("workflows")).to eq([crawler.fetch("name")])
    end

    it "listens for completion rather than success" do
      # `success` is not a valid workflow_run activity type; the conclusion is
      # filtered centrally instead, by data-deploy.yml's build_index_page `if:`.
      expect(workflow_run.fetch("types")).to eq(["completed"])
    end

    it "accepts the same default branches as the push trigger" do
      # `workflow_run`'s branch filter matches the *triggering* run's branch.
      # Listing the same set as `push` keeps the template repo-agnostic (many
      # relaton-data-* repos moved their default branch to v2), so this needs no
      # per-repo edit. Publication is still gated on the repo's real default
      # branch inside data-deploy.yml.
      expect(workflow_run.fetch("branches")).to eq(triggers.fetch("push").fetch("branches"))
    end
  end

  it "schedules its fallback cron clear of the crawler's observed window" do
    # A fallback for days the crawler commits nothing, not the primary path.
    # The old "one hour after the crawl" gap was inside the drift, so require a
    # real margin over the crawler template's own cron.
    expect(cron_hour.call(triggers.fetch("schedule")))
      .to be >= cron_hour.call(crawler.fetch(true).fetch("schedule")) + 3
  end

  describe "what it deliberately leaves to the shared workflow" do
    deploy_job = deploy.fetch("jobs").fetch("deploy")

    it "calls the shared data-deploy.yml" do
      expect(deploy_job.fetch("uses")).to eq("relaton/support/.github/workflows/data-deploy.yml@main")
    end

    it "declares no concurrency of its own" do
      # data-deploy.yml owns it (see spec/data_deploy_workflow_spec.rb). A
      # duplicate group here would only add a second queue in front of the same
      # deployment, and per GitHub's docs a caller-side group that collides with
      # the called workflow's can cancel the caller.
      expect(deploy).not_to have_key("concurrency")
      expect(deploy_job).not_to have_key("concurrency")
    end

    it "carries no failed-crawler `if:` guard" do
      # Also central, so a repo whose deploy.yml drifts still gets it.
      expect(deploy_job).not_to have_key("if")
    end
  end
end
