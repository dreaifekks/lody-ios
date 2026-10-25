import Foundation

struct ChatFileLink {
  let path: String
  let line: Int?

  init?(_ href: String) {
    var value = href.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\", with: "/")
    let suffix = #"(?:#L([1-9][0-9]*)(?:C[0-9]+)?(?:-L?[0-9]+(?:C[0-9]+)?)?|:L([1-9][0-9]*)(?:C[0-9]+)?|:([1-9][0-9]*)(?::[0-9]+)?)$"#
    var start: Int?
    if let range = value.range(of: suffix, options: .regularExpression) {
      start = Int(value[range].drop(while: { !$0.isNumber }).prefix(while: \.isNumber))
      value.removeSubrange(range)
    }
    let windows = value.range(of: #"^[A-Za-z]:/"#, options: .regularExpression) != nil
    guard !value.isEmpty, !value.hasPrefix("#"), !value.hasPrefix("//"),
      windows || value.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression) == nil else { return nil }
    guard !value.contains("?"), !value.contains("#"),
      value.contains("/") || !(value as NSString).pathExtension.isEmpty else { return nil }
    value = value.removingPercentEncoding ?? value
    guard !value.contains("\0"), value.utf8.count <= 32768 else { return nil }
    path = value
    line = start
  }

  static func iconName(for path: String) -> String {
    let name = (path as NSString).lastPathComponent.lowercased()
    if name == "dockerfile" { return "docker" }
    if name == "package.json" { return "nodejs" }
    if name.hasPrefix(".git") { return "git" }
    switch (name as NSString).pathExtension {
    case "md", "markdown", "mdx": return "markdown"
    case "png", "jpg", "jpeg", "gif", "webp", "heic", "svg", "ico": return "image"
    case "pdf": return "pdf"
    case "mp4", "mov", "m4v", "webm": return "video"
    case "mp3", "wav", "m4a", "aac", "flac": return "audio"
    case "zip", "gz", "tar", "7z", "rar": return "zip"
    case "swift": return "swift"
    case "ts", "mts", "cts": return "typescript"
    case "tsx": return "react_ts"
    case "js", "mjs", "cjs": return "javascript"
    case "jsx": return "react"
    case "json", "jsonc": return "json"
    case "py": return "python"
    case "html", "htm": return "html"
    case "css": return "css"
    case "scss", "sass": return "sass"
    case "yml", "yaml": return "yaml"
    case "rs": return "rust"
    case "go": return "go"
    case "java": return "java"
    case "c", "h": return "c"
    case "cpp", "hpp", "cc": return "cpp"
    case "sh", "bash", "zsh": return "console"
    case "doc", "docx": return "word"
    case "ppt", "pptx": return "powerpoint"
    case "xls", "xlsx", "csv": return "table"
    case "txt", "rtf", "log": return "document"
    default: return "file"
    }
  }
}

/// Port of lan-hub linkify-file-paths.ts. Keep prose conservative and home paths verbatim.
enum ChatBareLinks {
  struct Segment: Equatable {
    let text: String
    var href: String? = nil
  }
  private static let asciiSegment = #"[A-Za-z0-9._-]+"#
  private static let nonASCII = #"(?:(?!\p{ASCII})[\p{L}\p{M}\p{N}])+"#
  private static let ext = #"\.[0-9]*[A-Za-z][A-Za-z0-9]*(?![A-Za-z0-9])"#
  private static let otherDot = #"\.[0-9]*(?![A-Za-z0-9])"#
  private static let segment = "(?=[\\p{L}\\p{M}\\p{N}._-])(?:" + nonASCII + "|[A-Za-z0-9_-]+|" + otherDot + "|" + ext + "(?!\\P{ASCII}))*(?:" + ext + ")?"
  private static let prefix = #"(?:(?:~|\.{0,2})[\\/])?"#
  private static let suffix = #"(?:#L[0-9]+(?:C[0-9]+)?(?:-L?[0-9]+(?:C[0-9]+)?)?|:L?[0-9]+(?:C[0-9]+)?(?::[0-9]+)?)"#
  private static let candidate = try! NSRegularExpression(pattern: prefix + asciiSegment + "(?:[\\\\/]" + segment + ")*(?:" + suffix + ")?")
  private static let asciiCandidate = try! NSRegularExpression(pattern: "^" + prefix + asciiSegment + "(?:[\\\\/]" + asciiSegment + ")*(?:" + suffix + ")?")
  private static let urls = try! NSRegularExpression(pattern: #"(?:https?://|www\.|lody://|session://)[^\s<]+"#, options: .caseInsensitive)
  private static let compound: Set<String> = ["d.ts", "d.cts", "d.mts", "antlers.html", "actions.ts", "effects.ts", "facade.ts", "reducer.ts", "selector.ts", "selectors.ts", "env.example", "component.dart", "component.ts", "component.js", "service.dart", "service.ts", "service.js", "directive.dart", "directive.ts", "directive.js", "module.dart", "module.ts", "module.js", "guard.dart", "guard.ts", "guard.js", "pipe.dart", "pipe.ts", "pipe.js", "test.mjs", "spec.mjs", "test.js", "spec.js", "test.ts", "spec.ts", "spec.jsx", "test.jsx", "spec.tsx", "test.tsx", "tsconfig.json", "tf.json", "go.mod", "stories.js", "stories.jsx", "stories.mdx", "story.js", "story.jsx", "stories.ts", "stories.tsx", "story.ts", "story.tsx", "stories.svelte", "story.mdx", "svelte.ts", "blade.php", "html.twig", "yml.dist", "yaml.dist", "freezed.dart", "g.dart", "xml.dist", "xml.dist.sample"]
  private static let extensions: Set<String> = ["orval", "nim", "f90", "f95", "f03", "f", "for", "pdf", "env", "pkl", "hs", "earthlyignore", "sol", "mdoc", "ml", "mli", "cmx", "stylelint", "lock", "cmake", "njk", "nunjucks", "csproj", "ruleset", "sln", "slnx", "suo", "vb", "vbs", "vcxitems", "vcxproj", "h", "liquid", "mdx", "svx", "cfml", "cfc", "lucee", "cfm", "erl", "hrl", "haml", "deno", "netlify", "vercel", "editorconfig", "tex", "sty", "dtx", "ltx", "drawio", "dio", "patch", "gif", "webm", "mkv", "flv", "vob", "ogv", "ogg", "gifv", "avi", "mov", "qt", "wmv", "yuv", "rm", "rmvb", "mp4", "m4v", "mpg", "mp2", "mpeg", "mpe", "mpv", "m2v", "mp3", "flac", "m4a", "wma", "aiff", "wav", "al", "http", "rest", "bru", "cls", "exe", "msi", "zig", "proto", "jenkinsfile", "jenkins", "tf", "tfvars", "tfstate", "woff", "woff2", "ttf", "eot", "suit", "otf", "bmap", "fnt", "odttf", "ttc", "font", "fonts", "sui", "ntf", "mrf", "ex", "exs", "eex", "leex", "heex", "twig", "yml", "yaml", "gradle", "pcss", "sss", "sbt", "scala", "sc", "styl", "prisma", "astro", "pulumi", "graphql", "gql", "rs", "ron", "swift", "rb", "erb", "svelte", "kt", "kts", "r", "rmd", "jade", "pug", "lua", "luau", "less", "java", "jsp", "dart", "fs", "fsx", "fsi", "fsproj", "cr", "cs", "cshtml", "csx", "jl", "ssh_config", "sh", "ksh", "csh", "tcsh", "zsh", "bash", "nu", "bat", "cmd", "awk", "fish", "exp", "ps1", "psm1", "psd1", "ps1xml", "psc1", "pssc", "py", "python", "go", "c", "i", "mi", "cc", "cpp", "cxx", "c++", "cp", "mm", "mii", "ii", "cu", "cuh", "jsx", "tsx", "vsixmanifest", "vsix", "pdb", "sql", "pks", "pkb", "accdb", "mdb", "sqlite", "sqlite3", "pgsql", "postgres", "psql", "db", "db3", "scss", "sass", "dockerignore", "dockerfile", "containerignore", "xml", "plist", "xsd", "dtd", "xsl", "xslt", "resx", "iml", "xquery", "tmLanguage", "manifest", "project", "dmn", "htaccess", "txt", "xlsx", "xlsm", "xls", "csv", "tsv", "psv", "ods", "ipynb", "svg", "css", "test", "js", "mjs", "cjs", "ts", "res", "resi", "json", "html", "htm", "shtml", "md", "png", "jpeg", "jpg", "ico", "tif", "tiff", "psd", "psb", "ami", "apx", "avif", "bmp", "bpg", "brk", "cur", "dds", "dng", "exr", "fpx", "gbr", "img", "jbig2", "jb2", "jng", "jxr", "pgf", "pic", "raw", "webp", "eps", "afphoto", "ase", "aseprite", "clip", "cpt", "heif", "heic", "kra", "mdp", "ora", "pdn", "reb", "sai", "tga", "xcf", "jfif", "ppm", "pbm", "pgm", "pnm", "svgx", "toml", "v", "nix", "fc", "mongodb", "lang", "mo", "po", "pot", "gleam", "clj", "cljs", "cljc", "coffee", "php", "pl", "pm"]
  private static let names: Set<String> = [".gitlab-ci.yml", "lunaria.config.json", "ec.config.mjs", ".mcattributes", ".mcdefinitions", ".mcignore", "uno.config.js", "uno.config.mjs", "uno.config.ts", "uno.config.mts", "unocss.config.js", "unocss.config.mjs", "unocss.config.ts", "unocss.config.mts", "knip.json", "knip.jsonc", ".knip.json", ".knip.jsonc", "knip.ts", "knip.js", "knip.config.ts", "knip.config.js", "dev.vars", "serverless.yml", "gatsby-config.js", "gatsby-config.mjs", "gatsby-config.ts", "gatsby-node.js", "gatsby-node.mjs", "gatsby-node.ts", "gatsby-browser.js", "gatsby-browser.tsx", "gatsby-ssr.js", "gatsby-ssr.tsx", "panda.config.ts", "sanity.cli.ts", "sanity.config.ts", "sanity.theme.mjs", "markdoc.config.ts", "keystatic.page.ts", "keystatic.config.ts", "bruno.json", "bun.lock", "bun.lockb", "bunfig.toml", "dune", "dune-project", "dune-workspace", "dune-workspace.dev", "drizzle.config.ts", ".stylelintrc", "stylelint.config.js", "stylelint.config.cjs", ".stylelintrc.json", ".stylelintrc.yaml", ".stylelintrc.yml", ".stylelintrc.js", ".stylelintrc.cjs", ".stylelintignore", ".stylelintcache", "cmakelists.txt", "cmakecache.txt", "nest-cli.json", ".nest-cli.json", "nestconfig.json", ".nestconfig.json", "contentlayer.config.ts", "contentlayer.config.js", "go.mod", "go.sum", "go.work", "go.work.sum", "deno.json", "deno.jsonc", "docusaurus.config.js", "docusaurus.config.ts", "netlify.json", "netlify.yml", "netlify.yaml", "netlify.toml", ".vercel", "vercel.json", ".vercelignore", "now.json", ".nowignore", ".editorconfig", "gulpfile.js", "gulpfile.mjs", "gulpfile.ts", "gulpfile.cts", "gulpfile.mts", "gulpfile.babel.js", "cypress.json", "cypress.env.json", "cypress.config.ts", "cypress.config.js", "cypress.config.cjs", "cypress.config.mjs", ".feature", "capacitor.config.json", "capacitor.config.ts", "ionic.config.json", ".io-config.json", "nodemon.json", "nodemon-debug.json", "jenkinsfile", "package.json", "package-lock.json", ".nvmrc", ".esmrc", ".node-version", "gradle.properties", "gradlew", "gradle-wrapper.properties", "postcss.config.js", "postcss.config.cjs", "postcss.config.mjs", "postcss.config.ts", "postcss.config.cts", "postcss.config.mts", ".postcssrc.js", ".postcssrc.cjs", ".postcssrc.ts", ".postcssrc.cts", ".postcssrc", ".postcssrc.json", ".postcssrc.yaml", ".postcssrc.yml", "prisma.yml", "astro.config.js", "astro.config.mjs", "astro.config.cjs", "astro.config.ts", "astro.config.cts", "astro.config.mts", "vite.config.js", "vite.config.mjs", "vite.config.ts", "vite.config.cjs", "vite.config.mts", "vite.config.cts", "vitest.config.js", "vitest.config.mjs", "vitest.config.ts", "vitest.config.cjs", "vitest.config.mts", "vitest.config.cts", ".babelrc", ".babelrc.js", ".babelrc.cjs", ".babelrc.mjs", ".babelrc.cts", ".babelrc.json", "babel.config.js", "babel.config.cjs", "babel.config.mjs", "babel.config.ts", "babel.config.cts", "babel.config.json", ".prettierrc", "prettier.config.js", "prettier.config.cjs", "prettier.config.mjs", ".prettierrc.js", ".prettierrc.cjs", ".prettierrc.mjs", ".prettierrc.json", ".prettierrc.json5", ".prettierrc.yaml", ".prettierrc.yml", ".prettierignore", ".prettierrc.toml", ".cursorrules", "CLAUDE.md", ".claude", ".clauderc", "claude.json", "claude.yaml", "claude.yml", ".claude.md", "claude-prompt.md", ".claudeignore", "tauri.conf.json", "tauri.linux.json", "tauri.windows.json", "tauri.macos.json", "tauri.android.json", "tauri.ios.json", "tauri.conf.toml", "tauri.linux.toml", "tauri.windows.toml", "tauri.macos.toml", "tauri.android.toml", "tauri.ios.toml", "pulumi.yaml", "pnpm-lock.yaml", "pnpm-workspace.yaml", ".pnpmfile.cjs", ".npmignore", ".npmrc", ".graphqlconfig", ".graphqlrc", ".graphqlrc.json", ".graphqlrc.js", ".graphqlrc.cjs", ".graphqlrc.ts", ".graphqlrc.toml", ".graphqlrc.yaml", ".graphqlrc.yml", "graphql.config.json", "graphql.config.js", "graphql.config.ts", "graphql.config.toml", "graphql.config.yaml", "graphql.config.yml", "svelte.config.js", "svelte.config.cjs", ".Rhistory", ".pug-lintrc", ".pug-lintrc.js", ".pug-lintrc.json", ".luacheckrc", ".pubignore", "requirements.txt", "pipfile", ".python-version", "manifest.in", "pylintrc", ".pylintrc", "pyproject.toml", "setup.cfg", "jest.config.js", "jest.config.cjs", "jest.config.mjs", "jest.config.ts", "jest.config.cts", "jest.config.mts", "jest.config.json", "jest.setup.js", "jest.setup.ts", "jest.json", ".jestrc", ".jestrc.js", ".jestrc.json", "dockerfile", "dockerfile.prod", "dockerfile.production", "dockerfile.dev", "dockerfile.development", "dockerfile.local", "dockerfile.test", "docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml", "firebase.json", ".firebaserc", "firestore.rules", "firestore.indexes.json", ".vscodeignore", ".hugo_build.lock", "robots.txt", "yarn.lock", "yarn", ".direnv", ".env", ".env.local", ".env.development", ".env.dev", ".env.production", ".env.prod", ".env.test", "pre-commit", "commit-msg", "pre-push", "post-merge", "rome.json", "biome.json", "biome.jsonc", "eslint.config.js", "eslint.config.cjs", "eslint.config.mjs", "eslint.config.ts", "eslint.config.cts", "eslint.config.mts", ".eslintrc.js", ".eslintrc.cjs", ".eslintrc.yaml", ".eslintrc.yml", ".eslintrc.json", ".eslintrc", ".eslintignore", ".eslintcache", ".git-blame-ignore", ".gitignore", ".gitignore-global", ".gitignore_global", ".gitconfig", ".gitattributes", ".gitmodules", ".gitkeep", ".gitinclude", "git-history", ".swcrc", "license", "license-agpl", "license-apache", "license-bsd", "license-mit", "license-gpl", "license-lgpl", "license.md", "license.rst", "license.txt", "LICENSE", "LICENSE.md", "LICENSE.txt", "next.config.js", "next.config.mjs", "next.config.ts", "next.config.mts", ".nuxtrc", ".nuxtignore", "nuxt.config.js", "nuxt.config.mjs", "nuxt.config.ts", "nuxt.config.mts", "fresh.config.js", "fresh.config.mjs", "fresh.config.ts", "fresh.config.mts", "angular-cli.json", ".angular-cli.json", "angular.json", "turbo.json", "tailwind.js", "tailwind.ts", "tailwind.config.js", "tailwind.config.cjs", "tailwind.config.mjs", "tailwind.config.ts", "tailwind.config.cts", "tailwind.config.mts", "tsconfig.json", "tsconfig.app.json", "tsconfig.editor.json", "tsconfig.spec.json", "tsconfig.base.json", "tsconfig.build.json", "tsconfig.eslint.json", "tsconfig.lib.json", "tsconfig.node.json", "tsconfig.test.json", "tsconfig.e2e.json", "tsconfig.web.json", "tsconfig.config.json", "tsconfig.vitest.json", "webpack.config.js", "webpack.config.ts", "rsbuild.config.js", "rsbuild.config.ts", "rsbuild.config.mjs", "rspack.config.js", "rspack.config.ts", ".oxlintrc.json", ".oxlintignore", ".nxignore", "nx.json", "components.json", "Makefile", "makefile", "CMakeLists.txt", "Dockerfile", "Jenkinsfile", "Gemfile", "Gemfile.lock", "Rakefile", "Cargo", "Cargo.toml", "Cargo.lock", "README", "README.md", "readme.md", "CHANGELOG", "CHANGELOG.md", "changelog.md", "CONTRIBUTING", "CONTRIBUTING.md", "wrangler.toml", "wrangler.json"]

  private static func qualifies(_ raw: String, prose: Bool) -> Bool {
    guard let parsed = ChatFileLink(raw) else { return false }
    let base = parsed.path
    let last = (base as NSString).lastPathComponent
    let dot = last.lastIndex(of: ".")
    let hasExtension = dot.map { $0 != last.startIndex && last.index(after: $0) < last.endIndex } ?? false
    if prose, base.range(of: #"\P{ASCII}"#, options: .regularExpression) != nil,
       last.range(of: #"\.[A-Za-z0-9]+$"#, options: .regularExpression) == nil { return false }
    if base.contains("/") {
      let first = base.components(separatedBy: "/")[0].components(separatedBy: ".")
      let domains: Set<String> = ["com", "org", "net", "io", "dev", "app", "co", "ai", "gov", "edu", "info"]
      return hasExtension && !(first.count > 1 && domains.contains(first.last!.lowercased()))
    }
    let lower = last.lowercased()
    let recognized = names.contains(lower) || names.contains(last)
      || compound.contains { lower.hasSuffix("." + $0) }
      || extensions.contains((lower as NSString).pathExtension)
    return hasExtension && recognized && (!prose || parsed.line != nil)
  }

  static func wholeFile(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
          qualifies(trimmed, prose: false) else { return nil }
    return trimmed
  }

  private static func proseFile(_ value: String) -> String? {
    let stripped = value.replacingOccurrences(of: #"[.,;:!?'")\]}>，。！？；：、）】」』》“”‘’]+$"#, with: "", options: .regularExpression)
    return qualifies(stripped, prose: true) ? stripped : nil
  }

  private static func session(_ value: String) -> Bool {
    if value.range(of: #"^session://[A-Za-z0-9_-]+/?$"#, options: .regularExpression) != nil { return true }
    guard value.range(of: #"^lody://session/[A-Za-z0-9_-]+(?:\?[^#\s\\%]*)?$"#, options: .regularExpression) != nil,
          let parts = URLComponents(string: value) else { return false }
    let query = parts.queryItems ?? []
    return Set(query.map(\.name)).count == query.count && query.allSatisfy {
      ["workspace", "tab"].contains($0.name) && ($0.value ?? "").range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil
    }
  }

  static func split(_ value: String) -> [Segment] {
    let source = value as NSString
    var result: [Segment] = []
    var cursor = 0
    func append(_ range: NSRange, href: String?) {
      if range.location > cursor { result.append(Segment(text: source.substring(with: NSRange(location: cursor, length: range.location - cursor)))) }
      result.append(Segment(text: source.substring(with: range), href: href))
      cursor = NSMaxRange(range)
    }
    let urlMatches = urls.matches(in: value, range: NSRange(location: 0, length: source.length))
    // URL spans are reserved before the file scan; file-like URL tails never become paths.
    var paths = candidate.matches(in: value, range: NSRange(location: 0, length: source.length)).compactMap { match -> (NSRange, String?)? in
      if urlMatches.contains(where: { NSIntersectionRange($0.range, match.range).length > 0 }) { return nil }
      if match.range.location > 0, ["@", "~"].contains(source.substring(with: NSRange(location: match.range.location - 1, length: 1))) { return nil }
      let raw = source.substring(with: match.range)
      var path = proseFile(raw)
      if path == nil, raw.range(of: #"\P{ASCII}"#, options: .regularExpression) != nil,
         let ascii = asciiCandidate.firstMatch(in: raw, range: NSRange(location: 0, length: (raw as NSString).length)) {
        path = proseFile((raw as NSString).substring(with: ascii.range))
      }
      guard let path else { return nil }
      return (NSRange(location: match.range.location, length: (path as NSString).length), path)
    }
    for match in urlMatches {
      let raw = source.substring(with: match.range)
      var url = raw.components(separatedBy: CharacterSet(charactersIn: "，。！？；：、（）【】「」『』《》　")).first!
      while let last = url.last, "]})\"'.,:;!?".contains(last) { url.removeLast() }
      if session(url) { paths.append((NSRange(location: match.range.location, length: (url as NSString).length), url)) }
    }
    for (range, href) in paths.sorted(by: { $0.0.location < $1.0.location }) { append(range, href: href) }
    if cursor < source.length { result.append(Segment(text: source.substring(from: cursor))) }
    return result
  }
}
