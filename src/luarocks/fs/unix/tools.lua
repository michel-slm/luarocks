
--- fs operations implemented with third-party tools for Unix platform abstractions.
local tools = {}

local fs = require("luarocks.fs")
local dir = require("luarocks.dir")
local cfg = require("luarocks.core.cfg")

local vars = setmetatable({}, { __index = function(_,k) return cfg.variables[k] end })

--- Adds prefix to command to make it run from a directory.
-- @param directory string: Path to a directory.
-- @param cmd string: A command-line string.
-- @return string: The command-line with prefix.
function tools.command_at(directory, cmd)
   return "cd " .. fs.Q(fs.absolute_name(directory)) .. " && " .. cmd
end

--- Create a directory if it does not already exist.
-- If any of the higher levels in the path name does not exist
-- too, they are created as well.
-- @param directory string: pathname of directory to create.
-- @return boolean: true on success, false on failure.
function tools.make_dir(directory)
   assert(directory)
   local ok, err = fs.execute(vars.MKDIR.." -p", directory)
   if not ok then
      err = "failed making directory "..directory
   end
   return ok, err
end

--- Remove a directory if it is empty.
-- Does not return errors (for example, if directory is not empty or
-- if already does not exist)
-- @param directory string: pathname of directory to remove.
function tools.remove_dir_if_empty(directory)
   assert(directory)
   fs.execute_quiet(vars.RMDIR, directory)
end

--- Remove a directory if it is empty.
-- Does not return errors (for example, if directory is not empty or
-- if already does not exist)
-- @param directory string: pathname of directory to remove.
function tools.remove_dir_tree_if_empty(directory)
   assert(directory)
   fs.execute_quiet(vars.RMDIR, "-p", directory)
end

--- Copy a file.
-- @param src string: Pathname of source
-- @param dest string: Pathname of destination
-- @param perm string ("read" or "exec") or nil: Permissions for destination 
-- file or nil to use the source permissions
-- @return boolean or (boolean, string): true on success, false on failure,
-- plus an error message.
function tools.copy(src, dest, perm)
   assert(src and dest)
   if fs.execute(vars.CP, src, dest) then
      if perm then
         if fs.is_dir(dest) then
            dest = dir.path(dest, dir.base_name(src))
         end
         if fs.set_permissions(dest, perm, "all") then
            return true
         else
            return false, "Failed setting permissions of "..dest
         end
      end
      return true
   else
      return false, "Failed copying "..src.." to "..dest
   end
end

--- Recursively copy the contents of a directory.
-- @param src string: Pathname of source
-- @param dest string: Pathname of destination
-- @return boolean or (boolean, string): true on success, false on failure,
-- plus an error message.
function tools.copy_contents(src, dest)
   assert(src and dest)
   if fs.execute_quiet(vars.CP.." -pPR "..fs.Q(src).."/* "..fs.Q(dest)) then
      return true
   else
      return false, "Failed copying "..src.." to "..dest
   end
end
--- Delete a file or a directory and all its contents.
-- For safety, this only accepts absolute paths.
-- @param arg string: Pathname of source
-- @return nil
function tools.delete(arg)
   assert(arg)
   assert(arg:sub(1,1) == "/")
   fs.execute_quiet(vars.RM, "-rf", arg)
end

--- Recursively scan the contents of a directory.
-- @param at string or nil: directory to scan (will be the current
-- directory if none is given).
-- @return table: an array of strings with the filenames representing
-- the contents of a directory.
function tools.find(at)
   assert(type(at) == "string" or not at)
   if not at then
      at = fs.current_dir()
   end
   if not fs.is_dir(at) then
      return {}
   end
   local result = {}
   local pipe = io.popen(fs.command_at(at, fs.quiet_stderr(vars.FIND.." *")))
   for file in pipe:lines() do
      table.insert(result, file)
   end
   pipe:close()
   return result
end

--- Compress files in a .zip archive.
-- @param zipfile string: pathname of .zip archive to be created.
-- @param ... Filenames to be stored in the archive are given as
-- additional arguments.
-- @return boolean: true on success, false on failure.
function tools.zip(zipfile, ...)
   return fs.execute(vars.ZIP.." -r", zipfile, ...)
end

--- Uncompress files from a .zip archive.
-- @param zipfile string: pathname of .zip archive to be extracted.
-- @return boolean: true on success, false on failure.
function tools.unzip(zipfile)
   assert(zipfile)
   return fs.execute_quiet(vars.UNZIP, zipfile)
end

--- Test is file/directory exists
-- @param file string: filename to test
-- @return boolean: true if file exists, false otherwise.
function tools.exists(file)
   assert(file)
   return fs.execute(vars.TEST, "-e", file)
end

--- Test is pathname is a directory.
-- @param file string: pathname to test
-- @return boolean: true if it is a directory, false otherwise.
function tools.is_dir(file)
   assert(file)
   return fs.execute(vars.TEST, "-d", file)
end

--- Test is pathname is a regular file.
-- @param file string: pathname to test
-- @return boolean: true if it is a regular file, false otherwise.
function tools.is_file(file)
   assert(file)
   return fs.execute(vars.TEST, "-f", file)
end

do
   local umask_cache
   function tools._unix_umask()
      if umask_cache then
         return umask_cache
      end
      local fd = assert(io.popen("umask"))
      local umask = assert(fd:read("*a"))
      umask = umask:gsub("\n", "")
      umask_cache = umask:sub(2, 4)
      return umask_cache
   end
end

--- Set permissions for file or directory
-- @param filename string: filename whose permissions are to be modified
-- @param mode string ("read" or "exec"): permissions to set
-- @param scope string ("user" or "all"): the user(s) to whom the permission applies
-- @return boolean or (boolean, string): true on success, false on failure,
-- plus an error message
function tools.set_permissions(filename, mode, scope)
   assert(filename and mode and scope)

   local perms
   if mode == "read" and scope == "user" then
      perms = fs._unix_moderate_permissions("600")
   elseif mode == "exec" and scope == "user" then
      perms = fs._unix_moderate_permissions("700")
   elseif mode == "read" and scope == "all" then
      perms = fs._unix_moderate_permissions("644")
   elseif mode == "exec" and scope == "all" then
      perms = fs._unix_moderate_permissions("755")
   else
      return false, "Invalid permission " .. mode .. " for " .. scope
   end
   return fs.execute(vars.CHMOD, perms, filename)
end

--- Unpack an archive.
-- Extract the contents of an archive, detecting its format by
-- filename extension.
-- @param archive string: Filename of archive.
-- @return boolean or (boolean, string): true on success, false and an error message on failure.
function tools.unpack_archive(archive)
   assert(type(archive) == "string")

   local pipe_to_tar = " | "..vars.TAR.." -xf -"

   if not cfg.verbose then
      pipe_to_tar = " 2> /dev/null"..fs.quiet(pipe_to_tar)
   end

   local ok
   if archive:match("%.tar%.gz$") or archive:match("%.tgz$") then
      ok = fs.execute_string(vars.GUNZIP.." -c "..fs.Q(archive)..pipe_to_tar)
   elseif archive:match("%.tar%.bz2$") then
      ok = fs.execute_string(vars.BUNZIP2.." -c "..fs.Q(archive)..pipe_to_tar)
   elseif archive:match("%.zip$") then
      ok = fs.execute_quiet(vars.UNZIP, archive)
   elseif archive:match("%.lua$") or archive:match("%.c$") then
      -- Ignore .lua and .c files; they don't need to be extracted.
      return true
   else
      return false, "Couldn't extract archive "..archive..": unrecognized filename extension"
   end
   if not ok then
      return false, "Failed extracting "..archive
   end
   return true
end

function tools.attributes(filename, attrtype)
   local flag = ((attrtype == "permissions") and vars.STATPERMFLAG)
             or ((attrtype == "owner") and vars.STATOWNERFLAG)
   if not flag then return "" end
   local pipe = io.popen(fs.quiet_stderr(vars.STAT.." "..flag.." "..fs.Q(filename)))
   local ret = pipe:read("*l")
   pipe:close()
   if ret == "" then
      return nil
   end
   return ret
end

function tools.browser(url)
   return fs.execute(cfg.web_browser, url)
end

-- Set access and modification times for a file.
-- @param filename File to set access and modification times for.
-- @param time may be a string or number containing the format returned
-- by os.time, or a table ready to be processed via os.time; if
-- nil, current time is assumed.
function tools.set_time(file, time)
   assert(time == nil or type(time) == "table" or type(time) == "number")
   file = dir.normalize(file)
   local flag = ""
   if type(time) == "number" then
      time = os.date("*t", time)
   end
   if type(time) == "table" then
      flag = ("-t %04d%02d%02d%02d%02d%02d"):format(time.year, time.month, time.day, time.hour, time.min, time.sec)
   end
   return fs.execute(vars.TOUCH .. " " .. flag, file)
end

--- Create a temporary directory.
-- @param name_pattern string: name pattern to use for avoiding conflicts
-- when creating temporary directory.
-- @return string or (nil, string): name of temporary directory or (nil, error message) on failure.
function tools.make_temp_dir(name_pattern)
   assert(type(name_pattern) == "string")
   name_pattern = dir.normalize(name_pattern)

   local template = (os.getenv("TMPDIR") or "/tmp") .. "/luarocks_" .. name_pattern:gsub("/", "_") .. "-XXXXXX"
   local pipe = io.popen(vars.MKTEMP.." -d "..fs.Q(template))
   local dirname = pipe:read("*l")
   pipe:close()
   if dirname and dirname:match("^/") then
      return dirname
   end
   return nil, "Failed to create temporary directory "..tostring(dirname)
end

return tools
