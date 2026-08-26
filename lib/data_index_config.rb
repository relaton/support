require "yaml"

# Reads `data-index/configs.yml`, the single source of truth for the
# relaton-data-* GitHub Pages index sites.
#
# Two commands consume it:
#
#   bin/index-branding   -> #branding, run by the "Resolve branding" step of
#                           .github/workflows/data-deploy.yml, which passes the
#                           result to `relaton index` as --title/--favicon/
#                           --description.
#   bin/check-data-pages -> #pages_url and #raw_index_urls, the rollout gate that
#                           requires 200 from the site and from one of the index
#                           candidates.
#
# This class used to also render a Jekyll `_config.yml` per repo. support#58
# (relaton/relaton#83) replaced that build with `relaton index`, which reads each
# data repo's own `data/` folder, so the renderer and its `pubid_class` /
# `pubid_require` / `paginate` inputs were removed.
class DataIndexConfig
  DEFAULT_CONFIG_PATH =
    File.expand_path("../data-index/configs.yml", __dir__).freeze

  # Default GitHub project-pages host for relaton-data-* sites
  # (https://relaton.github.io/relaton-data-<repo>/). Override with --base when a
  # repo serves Pages from a custom domain.
  PAGES_HOST = "https://relaton.github.io".freeze

  # The index filenames a data repo may publish, newest first.
  #
  # This file used to carry a per-row `source:` naming the one each repo served.
  # That key was a hand-copied echo of a fact that lives on
  # raw.githubusercontent.com, and it drifted twice: `iana` named an index its
  # repo had not published yet, `ietf` named one its repo had deleted. So
  # bin/check-data-pages probes these names instead and takes the first 200.
  #
  # Newest first matters. A repo mid-migration can serve two names at once, and
  # oldest-first would report the one it is retiring.
  INDEX_FILES = %w[index-v3.yaml index-v2.yaml index-v1.yaml].freeze

  attr_reader :defaults, :repos

  def self.load(path = DEFAULT_CONFIG_PATH)
    data = YAML.safe_load_file(path)
    new(data.fetch("defaults"), data.fetch("repos"))
  end

  # The configs.yml key for a repo named any of the ways a caller might have it:
  # "relaton/relaton-data-itu-r" ($GITHUB_REPOSITORY), "relaton-data-itu-r", or a
  # bare "itu-r". The owner is dropped rather than checked so a fork's PR build
  # resolves the same branding as the upstream repo.
  def self.flavor(repo)
    repo.to_s.split("/").last.to_s.sub(/\Arelaton-data-/, "")
  end

  def initialize(defaults, repos)
    @defaults = defaults
    @repos = repos
  end

  # Look up a single repo entry by its `repo` key.
  def entry(repo)
    find_entry(repo) or raise ArgumentError, "unknown repo: #{repo.inspect}"
  end

  # The branding `relaton index` renders into the Pages site — title, favicon and
  # `<meta name="description">` — resolved centrally rather than passed by each
  # caller. cimas.yml maps `.github/workflows/deploy.yml` as a whole-file copy for
  # 31 repos, so a `with:` block carrying these values is wiped on the next
  # `cimas sync` and the site silently loses them.
  #
  # Precedence: an explicit non-blank argument (a caller's workflow input) beats
  # this repo's configs.yml entry, which beats the shared default.
  #
  # Deliberately never raises, unlike #entry. Every repo Cimas syncs deploy.yml
  # into now carries a configs.yml row, so nothing exercises the fallback today —
  # it is a safety net, not a live path. It stays because a repo added to
  # cimas.yml before its row lands would otherwise fail its own Pages build on a
  # missing row. Such a repo falls back to what the workflow's own shell
  # derivation produced before this method existed — "<FLAVOR> Index" and no
  # branding. spec/cimas_data_pages_spec.rb is what makes the gap loud.
  #
  # => { "title" => String, "favicon" => String, "description" => String }
  def branding(repo, title: nil, favicon: nil, description: nil)
    found = find_entry(self.class.flavor(repo))

    {
      "title" => present(title) || (found ? entry_title(found) : derived_title(repo)),
      "favicon" => present(favicon) || (found ? entry_favicon(found) : ""),
      "description" => present(description) || (found ? entry_description(found) : ""),
    }
  end

  # The GitHub Pages site URL for a repo (what should return 200 once the
  # rollout lands). `base` overrides the default project-pages host.
  def pages_url(repo, base: PAGES_HOST)
    entry(repo) # validate the repo is known
    "#{base.chomp('/')}/relaton-data-#{repo}/"
  end

  # Every index URL a data repo might serve: `baseurl` (repo + real default
  # branch) + each INDEX_FILES name, newest first. Nothing here knows which one
  # a repo publishes today, and nothing needs to — bin/check-data-pages requires
  # 200 from the first that answers.
  def raw_index_urls(repo)
    e = entry(repo)
    INDEX_FILES.map { |file| "#{baseurl(e)}#{file}" }
  end

  # Pick the index a repo actually serves: the first candidate the block reports
  # 200 for, as `[status, url]`. The block takes a URL and returns its HTTP
  # status; it lives in bin/check-data-pages so this class stays offline and the
  # choosing logic stays under test.
  #
  # With no candidate live, this returns the last one tried rather than nil, so
  # a caller has a status to print. That is the oldest name, which is NOT a
  # statement that the repo should serve it — bin/check-data-pages says which
  # names it probed when it reports the miss.
  def first_live_index(repo, &probe)
    last = nil
    raw_index_urls(repo).each do |url|
      last = [probe.call(url), url]
      return last if last.first == 200
    end
    last
  end

  private

  # Nil-returning lookup; #entry raises on top of it.
  def find_entry(repo)
    repos.find { |e| e["repo"] == repo }
  end

  # The raw.githubusercontent baseurl for an entry (repo + real default branch).
  def baseurl(entry)
    format(defaults.fetch("baseurl_template"),
           repo: entry.fetch("repo"), branch: entry.fetch("branch"))
  end

  # The `entry_*` prefix is deliberate: #branding takes `favicon:`/`description:`
  # keyword arguments, and bare `favicon` there would read as the parameter.
  def entry_title(entry)
    "#{entry.fetch('display')} Index"
  end

  # Per-entry override or the shared default favicon.
  def entry_favicon(entry)
    override(entry, "favicon") || defaults.fetch("favicon")
  end

  # Per-entry override or the templated "Welcome to the <display> ..." line.
  def entry_description(entry)
    override(entry, "description") ||
      format(defaults.fetch("description_template"), display: entry.fetch("display"))
  end

  # What the workflow's retired shell step produced for a repo configs.yml does
  # not cover: the slug, upcased. Keeps such a repo building unchanged rather
  # than failing its deploy on a missing row.
  def derived_title(repo)
    "#{self.class.flavor(repo).upcase} Index"
  end

  # Read a per-entry string override, treating nil/blank as "not set".
  def override(entry, key)
    present(entry[key])
  end

  # nil/blank -> nil. Blank must mean "not set" for #branding's arguments too:
  # the workflow passes --title/--favicon/--description unconditionally, so an
  # unset caller input arrives as "" and has to fall through to configs.yml.
  def present(value)
    return nil if value.nil? || value.to_s.strip.empty?

    value
  end
end
