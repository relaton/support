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

  # Render the `_config.yml` text for a repo name.
  def render_repo(repo)
    render(entry(repo))
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

  # Render the `_config.yml` text for a raw entry hash (merged with defaults).
  #
  # `favicon`, `description`, and `pubid_require` accept an optional per-entry
  # override (used by the already-live ids/oasis/w3c, which keep their own
  # branding + w3c's non-default `relaton/w3c/pubid` require); absent, they fall
  # back to the shared default / templated value.
  def render(entry)
    lines = [
      # Shared with #branding so a repo's Pages title cannot drift from the one
      # its generated config claims.
      "title: #{entry_title(entry)}",
      "description: >-",
      # Every line indented, not just the first: an unindented continuation line
      # would terminate the `>-` block and make the rendered _config.yml invalid
      # YAML. Single-line values (all of them today) are unaffected.
      entry_description(entry).to_s.lines.map { |l| "  #{l.chomp}" }.join("\n"),
      "paginate: #{defaults.fetch('paginate')}",
      "jekyll-index:",
      "  favicon: #{sq(entry_favicon(entry))}",
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

  # Per-entry override or the shared default pubid require (`pubid`).
  def pubid_require(entry)
    override(entry, "pubid_require") || defaults.fetch("pubid_require")
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
