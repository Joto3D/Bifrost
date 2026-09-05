BIFROST — Valheim mod launcher
================================

Hey! This is Bifrost, a little app that finds your Valheim install
through Steam, installs the BepInEx mod loader for you, and lets you
browse and install mods from Thunderstore without touching a config file
or a command line. Then it has one button: Play Modded.


HOW TO RUN IT
-------------

1. Unzip this folder anywhere you like (Desktop, Documents, wherever).
2. Double-click Bifrost.exe.

That's it — there's nothing to install. Bifrost is a single .exe file.


"WINDOWS PROTECTED YOUR PC" WARNING
------------------------------------

The first time you run Bifrost.exe, Windows SmartScreen will probably
pop up a blue screen that says "Windows protected your PC". This is
normal and expected — it happens to every small, unsigned app that isn't
from a big company, and it does NOT mean anything is wrong with Bifrost.

To get past it:

  1. Click "More info" (small text, usually below the warning).
  2. Click "Run anyway".

Bifrost will then open normally. You only have to do this once — Windows
remembers your choice for this file.


FIRST STEPS INSIDE THE APP
---------------------------

When Bifrost opens, go to the Home tab:

  - If it says Valheim wasn't found: make sure Valheim is installed
    through Steam and that you've launched it at least once, then hit
    the Refresh button (top-right, the circular arrow).

  - If Valheim is found but there's a banner about BepInEx not being
    installed: click "Install BepInEx". This downloads the mod loader
    and copies it next to Valheim — it doesn't touch your save files.

  - Once both are green, hit the big "Play Modded" button. Use "Play
    Vanilla" any time you want to play without mods (your saves work
    fine either way).

To actually get some mods: go to the Browse tab, search for something
that sounds fun, and click Install. Installed mods show up (and can be
enabled/disabled/updated/removed) under the Installed tab.

Want a different look? Settings -> Appearance has six color themes to
pick from.


INSTALLING MODS FROM NEXUS MODS
--------------------------------

Some mods only live on Nexus Mods rather than Thunderstore. Bifrost can
catch those too:

  1. Go to Settings -> Nexus Mods, paste in your Nexus API key (get one
     free from nexusmods.com -> your account -> API Access, or just
     click the "Get your API key" button in Bifrost), and hit Save.
  2. On any Valheim mod page on the Nexus Mods website, click
     "Mod Manager Download" (NOT the manual download button).
  3. Bifrost catches the link and installs the mod automatically — no
     manual download, no unzipping.

If you ever get a Windows prompt asking which app should open nxm://
links, choose Bifrost.


SHARING A MODLIST WITH FRIENDS
-------------------------------

Playing with friends goes smoother when everyone runs the same mods.
From the Installed tab, click "Manage profiles...", pick a profile, and
use "Copy Share Code" (or "Export to File..." for a file you can email
or drop in Discord). Send that to a friend, who pastes it into their own
Bifrost's "Import..." button — it reviews what it'll install before
touching anything. This also works with r2modman/Thunderstore Mod
Manager codes, in either direction.

Heading to someone else's server for the first time? Try "Join a
Server..." on the Home tab instead — it walks you through a safe modlist
automatically (backing up your saves first) so risky world-altering mods
don't get in your way.


YOUR SAVES ARE BACKED UP AUTOMATICALLY
----------------------------------------

Bifrost quietly backs up your Valheim saves (worlds_local/characters_local)
before every modded launch, and again before switching profiles or
joining a server. You can see and restore any backup from Settings ->
Backups — nothing is ever deleted without you choosing it.


WHERE TO GET HELP
------------------

If something doesn't work, or a mod breaks your game, or Bifrost itself
looks broken — just message Joshua. Screenshots of whatever went wrong
help a lot.

Have fun!
