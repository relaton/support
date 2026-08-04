require "yaml"

# Renders the per-repo GitHub Pages index `_config.yml` for each relaton-data-*
# repo from the single source of truth in `data-index/configs.yml`.
#
# The rendered file is committed into the data repo itself (it is repo-owned,
# like relaton-data-oasis/w3c/ids already are); the theme's `data-deploy.yml`
# workflow merges it over the theme's base `_config.yml` at build time.
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

  def initialize(defaults, repos)
    @defaults = defaults
    @repos = repos
  end

  # Look up a single repo entry by its `repo` key.
  def entry(repo)
    repos.find { |e| e["repo"] == repo } or
      raise ArgumentError, "unknown repo: #{repo.inspect}"
  end

  # Render the `_config.yml` text for a repo name.
  def render_repo(repo)
    render(entry(repo))
  end

  # Render the `_config.yml` text for a raw entry hash (merged with defaults).
  #
  # `favicon`, `description`, and `pubid_require` accept an optional per-entry
  # override (used by the already-live ids/oasis/w3c, which keep their own
  # branding + w3c's non-default `relaton/w3c/pubid` require); absent, they fall
  # back to the shared default / templated value.
  def render(entry)
    display = entry.fetch("display")

    lines = [
      "title: #{display} Index",
      "description: >-",
      "  #{description(entry)}",
      "paginate: #{defaults.fetch('paginate')}",
      "jekyll-index:",
      "  favicon: #{sq(favicon(entry))}",
      "  source: #{sq(entry.fetch('source'))}",
      "  baseurl: #{sq(baseurl(entry))}",
      "  add_type_to_reference: true",
    ]

    pubid = pubid_class(entry)
    if pubid
      lines << "  pubid_class: #{sq(pubid)}"
      lines << "  pubid_require: #{sq(pubid_require(entry))}"
    end

    "#{lines.join("\n")}\n"
  end

  # The GitHub Pages site URL for a repo (what should return 200 once the
  # rollout lands). `base` overrides the default project-pages host.
  def pages_url(repo, base: PAGES_HOST)
    entry(repo) # validate the repo is known
    "#{base.chomp('/')}/relaton-data-#{repo}/"
  end

  # The raw index URL the theme plugin fetches at build time (`baseurl` + the
  # published `source`). A 404 here is the usual reason a built site renders
  # empty even when the Pages deploy itself is green.
  def raw_index_url(repo)
    e = entry(repo)
    "#{baseurl(e)}#{e.fetch('source')}"
  end

  private

  # The raw.githubusercontent baseurl for an entry (repo + real default branch).
  def baseurl(entry)
    format(defaults.fetch("baseurl_template"),
           repo: entry.fetch("repo"), branch: entry.fetch("branch"))
  end

  # Per-entry override or the shared default favicon.
  def favicon(entry)
    override(entry, "favicon") || defaults.fetch("favicon")
  end

  # Per-entry override or the templated "Welcome to the <display> ..." line.
  def description(entry)
    override(entry, "description") ||
      format(defaults.fetch("description_template"), display: entry.fetch("display"))
  end

  # Per-entry override or the shared default pubid require (`pubid`).
  def pubid_require(entry)
    override(entry, "pubid_require") || defaults.fetch("pubid_require")
  end

  # Read a per-entry string override, treating nil/blank as "not set".
  def override(entry, key)
    value = entry[key]
    return nil if value.nil? || value.to_s.strip.empty?

    value
  end

  # YAML single-quoted scalar with proper escaping ('' for a literal quote).
  def sq(value)
    "'#{value.to_s.gsub("'", "''")}'"
  end

  # Normalise the pubid class: blank -> nil (flat index), and strip any leading
  # "::" because the theme plugin resolves the name with Object.const_get, which
  # rejects a leading namespace separator.
  def pubid_class(entry)
    value = entry["pubid_class"]
    return nil if value.nil? || value.strip.empty?

    value.strip.sub(/\A::/, "")
  end
end
