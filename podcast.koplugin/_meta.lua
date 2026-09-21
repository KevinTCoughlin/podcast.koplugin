local _ = require("gettext")
-- No `name` field: PluginLoader derives it from the directory and warns that a
-- `name` in _meta.lua "is deprecated and will be ignored".
return {
    fullname = _("Podcasts"),
    description = _([[Subscribe to podcasts, download episodes and play them while you read.]]),
}
