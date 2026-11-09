// Everything that names the project or points outside the site lives here, so a
// rename or a new repository address is a one-file change.
export const site = {
  name: "Fyke",
  repo: import.meta.env.SITE_REPO || "https://github.com/CinematicGenius007/fyke",
  // The folder `git clone` creates, and the command line program's name.
  cloneDir: "fyke",
  cli: "fyke",
  dataFolder: "~/.fyke",
  // The install commands, one per line, shown on the home and install pages.
  zig: "0.17.1",
};

export const installCommands = (s = site) => [
  `git clone ${s.repo}.git`,
  `cd ${s.cloneDir}`,
  `python3 tools/bundle_app.py --install`,
];

export function url(path = ""): string {
  const base = import.meta.env.BASE_URL.replace(/\/$/, "");
  return `${base}/${path.replace(/^\//, "")}`;
}
