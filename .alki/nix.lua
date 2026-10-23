local nix = { name = "nix", version = "1", permissions = { "programs" } }

local allowed = { build = true, flake = true, eval = true, log = true, ["path-info"] = true }
local allowed_flake = { check = true, metadata = true, show = true }

nix.programs = {
  nix = {
    path = "/nix/var/nix/profiles/default/bin/nix",
    read = { "/nix", "/etc/nix", "~/.config/nix", "~/.gitconfig", "~/.config/git" },
    write = { "/nix/var/nix/daemon-socket", "~/.cache/nix", "~/.local/state/nix" },
    env = { "NIX_REMOTE", "NIX_CONFIG" },
    allow = function(args)
      local sub = args[1]
      if sub == nil then return false, "name a nix subcommand" end
      if not allowed[sub] then
        return false, "nix " .. sub .. " is not allowed: use build, flake, eval, log, or path-info"
      end
      if sub == "flake" and not allowed_flake[args[2] or ""] then
        return false, "only nix flake check, metadata, or show are allowed; updating the lock is the user's call"
      end
      return true
    end,
  },
}

return nix
