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
#   bin/check-data-pages -> #pages_url and #raw_index_url, the rollout gate that
#                           requires 200 from both.
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
  # 30 repos, so a `with:` block carrying these values is wiped on the next
  # `cimas sync` and the site silently loses them.
  #
  # Precedence: an explicit non-blank argument (a caller's workflow input) beats
  # this repo's configs.yml entry, which beats the shared default.
  #
  # Deliberately never raises, unlike #entry: Cimas syncs deploy.yml into
  # relaton-data-ietf, which publishes no document index and so has no configs.yml
  # row. An unknown repo falls back to what the workflow's own shell derivation
  # produced before this method existed — "<FLAVOR> Index" and no branding.
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

  # The published index a data repo serves: `baseurl` (repo + real default
  # branch) + `source`. bin/check-data-pages requires 200 from it, so a row's
  # `source` has to name the index that repo publishes today, not the one its
  # relaton consumer is moving to.
  def raw_index_url(repo)
    e = entry(repo)
    "#{baseurl(e)}#{e.fetch('source')}"
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
  # not cover: the slug, upcased. Keeps relaton-data-ietf building unchanged.
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
