-- AlterAeon script (ported from the old compiled Swift package).
--
-- The heavy KXWT protocol parsing stays on the host (see KXWTHost.swift); this
-- script just declares triggers/aliases/gags and forwards kxwt payloads via the
-- host `kxwt(...)` builtin. Trigger/alias patterns are Swift regular expressions.
--
-- Builtins provided by the host:
--   send(text)        send a command to the MUD
--   echo(text)        print to the local terminal
--   kxwt(payload)     hand a kxwt_<payload> line to the host parser
--   recover()         toggle the recovery routine
--   dump_state()      echo the parsed game state

trigger("(.+) is DEAD!", function(line)
    send("cry")
end)

trigger("^kxwt_supported$", function()
    send("set kxwt")
end)

-- Any other kxwt_<payload> line: forward the payload to the host parser.
trigger("^kxwt_(.+)$", function(line, payload)
    kxwt(payload)
end)

-- kxwt control lines are machinery, not for the player to see.
gag("^kxwt_")

alias("^state$", function()
    dump_state()
end)

alias("^recover$", function()
    recover()
end)
