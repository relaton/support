require "json"
require "yaml"

# Reads `data-index/configs.yml`, the single source of truth for the
# relaton-data-* GitHub Pages index sites.
#
# Two commands consume it:
#
#   bin/index-branding   -> #branding, run by the "Resolve branding" step of
#                           .github/workflows/data-deploy.yml, which passes the
#                           result to `relaton index` as --title/--favicon/
#                           --description/--pubid-flavor.
#   bin/check-data-pages -> #pages_url, #manifest_url and #raw_index_url, the
#                           rollout gate that requires 200 from the site and
#                           from the index the site's own manifest names.
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

  # A monolith BASE name as the manifest carries it: one path segment and no
  # extension, because #raw_index_url appends `.yaml`. So a manifest reading
  # `"index": "index-v2.yaml"` is rejected rather than turned into
  # `index-v2.yaml.yaml`, a dead URL that would report a healthy site as broken.
  # Stricter than the generator's own `--index-name` check, which allows a dot.
  INDEX_NAME = /\A[A-Za-z0-9][A-Za-z0-9_-]*\z/.freeze

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
  # It also carries the machine-index flags, which are not branding but travel
  # the same path: configs.yml -> bin/index-branding -> $GITHUB_OUTPUT -> the
  # build step. They cannot ride in a caller `with:` block for the same reason
  # the branding cannot.
  #
  # `machine_index` is "false" only on the fallback path. `--pubid-flavor` is
  # mandatory since relaton#114, so a repo with no row and no flavor would fail
  # its Pages build outright; `--no-machine-index` builds the human site
  # instead, which is what such a repo published before any of this existed.
  #
  # There is no `index_name`: `relaton index` derives the published index's
  # name from the flavor's own `INDEXFILE`, so the flavor is the whole input.
  # `--index-name` exists for a corpus that is not a relaton flavor, and every
  # row here is one.
  #
  # => { "title" => String, "favicon" => String, "description" => String,
  #      "pubid_flavor" => String, "machine_index" => String,
  #      "publish_data" => String }
  def branding(repo, title: nil, favicon: nil, description: nil)
    found = find_entry(self.class.flavor(repo))

    {
      "title" => present(title) || (found ? entry_title(found) : derived_title(repo)),
      "favicon" => present(favicon) || (found ? entry_favicon(found) : ""),
      "description" => present(description) || (found ? entry_description(found) : ""),
      "pubid_flavor" => found ? present(found["pubid_flavor"]).to_s : "",
      # Keyed on the flavor, not on the row: a row that lost its
      # `pubid_flavor` to a bad merge would otherwise ask for a machine index
      # and hand the build `--pubid-flavor ""`. spec/data_index_config_spec.rb
      # catches such a row at PR time; this keeps the deploy building anyway.
      "machine_index" => found && present(found["pubid_flavor"]) ? "true" : "false",
      "publish_data" => found && found["publish_data"] ? "true" : "false",
    }
  end

  # The GitHub Pages site URL for a repo (what should return 200 once the
  # rollout lands). `base` overrides the default project-pages host.
  def pages_url(repo, base: PAGES_HOST)
    entry(repo) # validate the repo is known
    "#{base.chomp('/')}/relaton-data-#{repo}/"
  end

  # The machine index's manifest on the Pages site. It carries `"index"`, the
  # base name of the monolith that build published — `relaton index` resolved
  # it from the flavor's own `Relaton::<Flavor>::INDEXFILE`, so the manifest is
  # that constant, carried by the build that used it. This file names no index
  # and guesses none: a `source:` key drifted here twice before it was removed,
  # and a candidate list would have to be hand-edited each time a flavor bumps
  # its index version.
  def manifest_url(repo, base: PAGES_HOST)
    "#{pages_url(repo, base: base)}index/manifest.json"
  end

  # The raw URL for one index name — the manifest's answer turned into the URL
  # the relaton gems fetch.
  def raw_index_url(repo, name)
    "#{baseurl(entry(repo))}#{name}.yaml"
  end

  # The monolith base name a manifest body names, or nil. Everything that is not
  # a plain file name is nil: the value is pasted into a URL, and the body may
  # be a 404 page, an empty response or a truncated file. Kept pure so the
  # checker stays the only part that touches the network.
  def self.index_from_manifest(body)
    data = JSON.parse(body.to_s)
    return nil unless data.is_a?(Hash)

    name = data["index"]
    return nil unless name.is_a?(String) && INDEX_NAME.match?(name)

    name
  rescue JSON::ParserError
    nil
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
