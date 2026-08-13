# Guards the Cimas caller template that Cimas syncs into every relaton-data-*
# repo as `.github/workflows/deploy.yml`.
#
# The problem it encodes: a `push` trigger could never fire on crawled data.
# crawler.yml's "Push data" step commits with the default actions/checkout
# GITHUB_TOKEN, and GitHub deliberately raises no workflow events for
# GITHUB_TOKEN pushes. That left the daily cron as the only path from crawl to
# Pages — and it assumed a fixed one-hour gap that scheduled dispatch does not
# honour (11 of relaton-data-iana's last 12 Crawler runs *started* at or after
# 14:58 UTC despite a 14:00 cron, several past 16:00), so the 15:00 deploy
# usually indexed the previous day's data. Both templates have since dropped
# `push` and `pull_request` entirely; what remains is asserted below.
#
# Ordering is now deterministic via `workflow_run`. The couplings below are all
# silent when broken — nothing goes red in CI, the fleet just quietly stops
# republishing — so they are pinned here.
RSpec.describe "cimas-config/gh-actions/data/deploy.yml" do
  repo_root = File.expand_path("..", __dir__)
  template = ->(name) { YAML.safe_load_file(File.join(repo_root, "cimas-config/gh-actions/data", name)) }

  deploy = template.call("deploy.yml")
  crawler = template.call("crawler.yml")
  # The authority on which repos this template is synced into, and on each one's
  # real default branch.
  cimas = YAML.safe_load_file(File.join(repo_root, "cimas-config/cimas.yml"))
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

    it "accepts every default branch name in use across the fleet" do
      # `workflow_run`'s branch filter matches the *triggering* run's branch, so
      # this list has to cover every default branch the synced repos actually
      # use (23 of the 29 are on v2, the rest on main or master) for the file to
      # stay repo-agnostic. Publication is still gated on the repo's real
      # default branch inside data-deploy.yml.
      #
      # Derived from cimas.yml rather than hardcoded, and compared against the
      # `push` trigger before that — this template has neither a `push` block
      # any more nor a list that is right by construction. A repo moving to a
      # fourth default branch would otherwise silently stop republishing: the
      # trigger just never fires there, with nothing red anywhere.
      repositories = cimas.fetch("repositories")
      defaults = cimas.fetch("groups").fetch("data").filter_map do |name|
        repositories.dig(name, "branch") if
          (repositories.dig(name, "files") || {}).key?(".github/workflows/deploy.yml")
      end

      expect(defaults).not_to be_empty
      expect(workflow_run.fetch("branches")).to include(*defaults.uniq)
    end
  end

  describe "what neither template triggers on any more" do
    crawler_triggers = crawler.fetch(true)

    it "crawls only on a schedule or by hand" do
      # A `pull_request` crawl fetched an entire corpus and then threw it away:
      # crawler.yml's "Push data" step is gated `github.event_name !=
      # 'pull_request'`. On the largest flavors (ids at 166,658 documents, 3gpp
      # at 88,464) that is a very long run for nothing. `push` only re-ran what
      # the cron runs anyway, and `workflow_dispatch` covers wanting one sooner.
      #
      # The acknowledged cost: each data repo carries its own `crawler.rb`, and
      # the PR run was the only way to exercise a change to it without
      # committing — a dispatch run is not gated by that step and pushes its
      # crawled corpus to the branch it runs on.
      expect(crawler_triggers.keys).to contain_exactly("schedule", "workflow_dispatch")
    end

    it "deploys only from a finished crawl, the fallback cron, or by hand" do
      # A `pull_request` deploy ran the whole build — npm ci and the Vue compile
      # under `source: git`, then a full corpus parse and a Pages artifact
      # upload — and then skipped `deploy`, because publication is gated on the
      # repo's default branch. Minutes per PR for output nobody can see.
      #
      # `workflow_run` stays: it is not push-driven, and it is the only thing
      # that makes publication track the crawl rather than a cron guessed to
      # land after it (see the note at the top of this file).
      expect(triggers.keys).to contain_exactly("workflow_run", "schedule", "workflow_dispatch")
    end

    it "leaves no push or pull_request trigger in either template" do
      # Stated separately from the two `contain_exactly` examples above because
      # this is the invariant that fails silently: re-adding either trigger just
      # burns Actions minutes fleet-wide, in 29 repos at once, with nothing red.
      [triggers, crawler_triggers].each do |t|
        expect(t).not_to have_key("push")
        expect(t).not_to have_key("pull_request")
      end
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

    it "passes no inputs at all" do
      # THE reason branding moved into data-index/configs.yml. cimas.yml maps
      # this file into 29 repos as a whole-file copy, so anything in a `with:`
      # here is either wrong for the other 28 or — once a repo hand-edits it —
      # silently reverted by the next `cimas sync`. Branding failed silently (the
      # page just loses its favicon), which is why it moved to configs.yml.
      #
      # `source: git` used to be the one deliberate exception, because losing it
      # failed loudly with `Could not find command "index"`. It no longer needs
      # to be anywhere: `source` defaults to `git` in the shared workflow, so the
      # twelve callers still carrying the pin can lose it to a sync harmlessly.
      expect(deploy_job).not_to have_key("with")
    end
  end
end
