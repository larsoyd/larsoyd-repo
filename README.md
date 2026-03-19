# larsoyd

My local packaging workspace and binary repo for the publishing and maintenance of my patched downstream packages targeting Arch Linux.

This repo is the working tree behind `/srv/larsoyd`. It is built around Arch’s packaging and repo tooling:

- `pkgctl` for packaging repo operations and clean-chroot builds 
- `makepkg` for package metadata generation and artifact discovery via `--printsrcinfo` and `--packagelist` 
- `repo-add` for generating the pacman repo database from built package files 
- `pacman` for consuming the published local repo 
- `topgrade` as an optional runner through `pre_commands` 

## Layout after repo-add

```text
.
├── bin/
│   └── pkg-refresh.zsh
├── logs/
│   └── pkg-refresh/
├── manifests/
│   └── audacity.zsh
├── repo/
│   ├── builds/
│   ├── current
│   ├── pool/
│   └── snapshots/
├── src/
│   └── audacity/
└── state/
    └── pkg-refresh/
````

### What each directory is for

* `bin/`
  Runtime scripts. The main entrypoint is `pkg-refresh.zsh`.

* `src/`
  Source packaging repos. Each package lives in its own Git repo under `src/<project>`.

* `manifests/`
  One manifest per managed package. These live **outside** the packaging repos so they are not removed by `pkgctl repo clean`, which recursively removes files unknown to Git and ignored files. 

* `state/`
  Per-project state, locks, and last-success markers.

* `logs/`
  Per-project refresh logs.

* `repo/pool/`
  Stored package artifacts.

* `repo/builds/<timestamp>/`
  Composed repo views for publication.

* `repo/current`
  Symlink to the currently published repo view.

* `repo/snapshots/`
  Legacy one-package publication history kept for rollback / migration history.

## How it works

Each managed project has:

1. a packaging repo in `src/<project>`
2. a manifest in `manifests/<project>.zsh`
3. per-project state in `state/pkg-refresh/<project>`
4. logs in `logs/pkg-refresh/<project>`

`bin/pkg-refresh.zsh` does the following:

1. discovers manifests
2. checks whether upstream or local packaging changed
3. fetches and rebases the local branch
4. runs `pkgctl repo clean`
5. builds in a clean chroot with `pkgctl build`
6. gets the expected package filenames using `makepkg --packagelist`
7. stages packages into `repo/pool/<arch>`
8. creates a composed repo view in `repo/builds/<timestamp>/<arch>`
9. runs `repo-add` to generate `larsoyd.db`
10. switches `repo/current` to the new build

This is to match Arch’s recommended ALPM repo model: package files can be retained in a pool while the active repo state is exposed through a current view. 

## Current managed package(s)

```md
# audacity
## CHANGELOG
My modification of audacity ships with a single patch entitled `larsoyd-gtk-native-file-dialog.patch`
This patch modifies Audacity to support GTK native file dialogs (GtkFileChooserNative) in it's custom FileDialog wrapper,
This is to specifically make the KDE/portal-based file picker appear on GTK 3.20+ systems
instead of Audacity's embedded GTK file chooser widget.
```

## Installation

### Prerequisites

Install the tools used by the workflow:

```zsh
sudo pacman -S --needed git devtools pacman-contrib zsh
```

`devtools` provides Arch packaging maintainer tools, including `pkgctl`, and `pacman-contrib` provides `updpkgsums`. 

If you also want the Topgrade hook:

```zsh
# install topgrade however you prefer in your setup
```

### Clone the repo

```zsh
cd /srv
sudo git clone --recurse-submodules git@github.com:larsoyd/larsoyd-repo.git larsoyd
sudo chown -R $USER:alpm /srv/larsoyd
```

### Create runtime directories

Because generated state is not tracked, create it after clone:

```zsh
cd /srv/larsoyd
mkdir -p logs/pkg-refresh
mkdir -p repo/builds repo/pool/$(uname -m) repo/snapshots
mkdir -p state/pkg-refresh
chmod +x bin/pkg-refresh.zsh
```

### Build and publish the local repo

```zsh
/srv/larsoyd/bin/pkg-refresh.zsh list
/srv/larsoyd/bin/pkg-refresh.zsh audacity
```

That will build the package, stage artifacts, run `repo-add`, and populate the current repo view. `repo-add` updates a package database by reading built package files, and accepts multiple packages on the command line. 

### Add the local repo to pacman

Add a repository section to `/etc/pacman.conf` that points to the generated repo view:

```ini
[larsoyd]
Server = file:///srv/larsoyd/repo/current/$arch
```

`pacman.conf` is divided into repository sections, and each section defines a package repository pacman can use in sync mode. You will also need a `SigLevel` that matches how you handle signatures in your own setup. I am not asserting a single universal value here, because that depends on whether you sign the packages and database. If unsure, add `SigLevel = Optional TrustAll`

Then refresh:

```zsh
sudo pacman -Sy
```

## Optional: How to install directly from a published remote repo

If you later  want users to install from your repo without building locally, publish the contents of the generated repo view, meaning the database files and package files from the active repo, to a static host. Then users can add something like:

```ini
[larsoyd]
Server = https://example.invalid/larsoyd/$arch
```


## Adding a new package

### 1. Create or clone the packaging repo

After the package exists as an Arch packaging repo, clone a pkg with `pkgctl repo clone`. That command is intended for cloning packaging repositories from the canonical namespace. 

```zsh
cd /srv/larsoyd/src
pkgctl repo clone <pkgbase>
```

If the package is not available as an Arch packaging repo, create a normal Git repo under `src/<project>` and add a valid `PKGBUILD`.

A minimally functional `PKGBUILD` must define `pkgname`, `pkgver`, `pkgrel`, and `arch`. 

### 2. Create your downstream branch

Keep your local changes as Git commits on a local branch, for example:

```zsh
cd /srv/larsoyd/src/<project>
git switch -c larsoyd/main
```

Use a small downstream delta: patches, small PKGBUILD changes, package renames, local defaults, and so on.

### 3. Regenerate metadata when needed

If you change PKGBUILD metadata, regenerate `.SRCINFO` with:

```zsh
makepkg --printsrcinfo > .SRCINFO
```

`makepkg --printsrcinfo` is the supported way to generate `.SRCINFO`. 

If you change sources or checksums, update them with:

```zsh
updpkgsums
```

`updpkgsums` updates checksums in place, defaulting to `PKGBUILD` in the current directory. 

Commit tracked changes before running automation.

### 4. Add a manifest

Create `manifests/<project>.zsh`:

```zsh
PROJECT_ID=myproject
ENABLED=1

WORKTREE=/srv/larsoyd/src/myproject

UPSTREAM_REMOTE=upstream
UPSTREAM_BRANCH=main
LOCAL_BRANCH=larsoyd/main

REPO_NAME=larsoyd
```

### 5. Run the refresh tool

List managed projects:

```zsh
/srv/larsoyd/bin/pkg-refresh.zsh list
```

Refresh one project:

```zsh
/srv/larsoyd/bin/pkg-refresh.zsh myproject
```

Refresh all enabled projects:

```zsh
/srv/larsoyd/bin/pkg-refresh.zsh refresh
```

## Daily workflow

Normal package maintenance looks like this:

1. edit patch files and/or `PKGBUILD`
2. regenerate `.SRCINFO` if needed
3. update checksums if sources changed
4. commit tracked changes
5. run:

```zsh
/srv/larsoyd/bin/pkg-refresh.zsh <project>
```

Or let Topgrade call it for you through `pre_commands`. 

## Verify publication

After a successful refresh:

```zsh
readlink -f /srv/larsoyd/repo/current
ls -l /srv/larsoyd/repo/current/$(uname -m)
sudo pacman -Sy
pacman -Si <package-name>
```

`repo-add` updates the repo database from built package files, and pacman needs a refresh after new packages are added or the repo database changes. 

## Cleaning the source packaging repo

To manually remove untracked build products from a packaging repo:

```zsh
cd /srv/larsoyd/src/<project>
pkgctl repo clean
```

`pkgctl repo clean` recursively removes files not tracked by Git and ignored files. 

## Topgrade integration

This setup is intended to run before the normal system update by using Topgrade’s `pre_commands`. Topgrade’s example config documents `pre_commands` as commands run before anything else. 

Example:

```toml
[misc]
pre_sudo = true
ask_retry = false
notify_end = "on_failure"

[pre_commands]
"larsoyd packaging refresh" = "/srv/larsoyd/bin/pkg-refresh.zsh refresh"
```


## Troubleshooting

### `working tree is dirty`

Commit or discard tracked changes first. If PKGBUILD metadata changed, regenerate `.SRCINFO` and commit that too. `makepkg --printsrcinfo` is the canonical generator. 

### manifest disappeared

Keep manifests in `manifests/`, not inside `src/<project>`. `pkgctl repo clean` removes untracked files inside packaging repos. 

### package built but repo compose failed

Check:

```zsh
cat /srv/larsoyd/state/pkg-refresh/<project>/latest-packages
ls -l /srv/larsoyd/repo/pool/$(uname -m)
ls -l /srv/larsoyd/repo/current/$(uname -m)
```

`makepkg --packagelist` is the source of truth for expected artifact names. 

### Topgrade shows package refresh first and then starts system updates

That is expected. The package refresh is a `pre_commands` step, so it runs before the rest of the Topgrade flow. 

## Notes

* `repo/snapshots/` is legacy migration history from the older one-package publisher.
* `repo/pool/` + `repo/builds/` + `repo/current` is the active publication model.
* Split packages are supported naturally because `makepkg --packagelist` returns all produced package files. 
