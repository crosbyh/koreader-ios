-- Set search path for `require()`.
package.path =
    "common/?.lua;frontend/?.lua;plugins/exporter.koplugin/?.lua;" ..
    package.path
package.cpath =
    "common/?.so;common/?.dll;/usr/lib/lua/?.so;" ..
    package.cpath
-- iOS: the App Store rejects loose dylibs, so the Xcode post-build step
-- (platform/ios/embed-bundle-payload.sh) moves each one into
-- Frameworks/<name>.framework and writes `ios-frameworks.lua`, mapping the
-- original library file names to framework names. Redirect loads there.
if os.getenv("KO_IOS") == "1" then
    local frameworks_dir = os.getenv("KO_IOS_FRAMEWORKS")
    local ok, frameworks = pcall(dofile, "ios-frameworks.lua")
    if frameworks_dir and ok and type(frameworks) == "table" then
        local ffi = require("ffi")
        local function frameworkPath(lib)
            local name = frameworks[lib:match("[^/]+$")]
            return name and string.format("%s/%s.framework/%s", frameworks_dir, name, name)
        end
        local ffi_load, package_loadlib, package_searchpath = ffi.load, package.loadlib, package.searchpath
        ffi.load = function(lib, global)
            return ffi_load(frameworkPath(lib) or lib, global)
        end
        package.loadlib = function(lib, funcname)
            return package_loadlib(frameworkPath(lib) or lib, funcname)
        end
        -- The library files themselves are gone, so `ffi.loadlib` candidates
        -- have to be matched against the map rather than the filesystem.
        package.searchpath = function(name, path, sep, rep)
            local found, err = package_searchpath(name, path, sep, rep)
            if found then
                return found
            end
            local filename = name
            if sep ~= "" then
                filename = name:gsub((sep or "."):gsub("%p", "%%%0"), function() return rep or "/" end)
            end
            for template in path:gmatch("[^;]+") do
                local candidate = template:gsub("%?", function() return filename end)
                if frameworkPath(candidate) then
                    return candidate
                end
            end
            return nil, err
        end
    end
end

-- Setup `ffi.load` override and 'loadlib' helper.
require("ffi/loadlib")
