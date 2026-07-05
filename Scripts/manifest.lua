-- Script load order for load("Scripts") (see the loader in Scripts/bootstrap.lua).
--
-- Top-level order matters: AlterAeon defines the shared `state` table and the core kxwt_* triggers the
-- other scripts build on, and trigger registration order is firing order (AlterAeon's kxwt gags before
-- the pilot's catch-all observer). Alphabetical would load AIPilot before AlterAeon, so we pin the
-- order explicitly here. Any *.lua the manifest omits still loads, alphabetically, after these.
--
-- Base names (the `.lua` is optional). This file is itself excluded from loading.
return { "AlterAeon", "AIPilot", "HUD", "Trivia", "Equipment" }
