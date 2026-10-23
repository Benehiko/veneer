local rsvg = { name = "rsvg", version = "1", permissions = { "programs" } }

rsvg.programs = {
  ["rsvg-convert"] = {
    path = "/usr/bin/rsvg-convert",
  },
}

return rsvg
