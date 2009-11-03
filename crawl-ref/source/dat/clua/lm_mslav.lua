----------------------------------------------------------------------------
-- lm_mslav.lua
--
-- Wraps a marker to act as a master firing synchronized events to its
-- own position, and to any number of (or zero) slave markers'
-- positions.
--
-- API: lmark.synchronized_markers(<marker>, <trigger-function-names>)
-- 
-- (Some markers may already provide convenience functionality for the
--  synchronized_markers call, so check the relevant marker file.)
--
-- Usage:
-- ------
--
-- You can use synchronized_markers() if you have a marker that
-- performs an activity at random intervals, and you want to apply
-- this marker's effects to multiple locations at the same time.
--
-- As an example, take a fog machine:
-- 1) Create the fog machine as you would normally:
--        local fog = fog_machine {
--                            cloud_type = 'flame',
--                            size = 3, pow_min=2,
--                            pow_max = 5, delay_min = 22, delay_max = 120,
--                          }
--
-- 2) Apply it as a Lua marker to one or more locations, wrapping it
--    with synchronized_markers():
--        lua_marker('m', lmark.synchronized_markers(fog, 'do_fog'))
--    Where 'do_fog' is the name of the trigger method on the
--    underlying marker (here the fog machine) that performs the
--    activity of interest (generating fog at some point). The first
--    parameter of this overridden method must be a dgn.point that
--    specifies where the effect occurs. The method may also take any
--    number of additional parameters.
--
--    You may override multiple methods on the base marker:
--        lmark.synchronized_markers(fog, 'do_fog', 'notify_listener')
--    The only requirement for an overridden method is that it take a
--    dgn.point as its first parameter.
--
-- Internals:
-- ---------
-- synchronized_markers() takes one marker instance, and creates one
-- master marker (which is based on the given marker instance) and
-- multiple slave markers (which are simple PortalDescriptor markers).
-- The only purpose of the slave markers is to be discoverable by
-- dgn.find_marker_positions_by_prop, given a unique, autogenerated
-- slave id.
--
-- The master marker operates normally, but calls to any of the trigger
-- methods (say 'do_fog') are intercepted. Every trigger call is performed
-- on the master's position, and then on all the slaves' positions.
----------------------------------------------------------------------------

util.namespace('lmark')

lmark.slave_cookie = 0

function lmark.next_slave_id()
  local slave_id = "marker_slave" .. lmark.slave_cookie
  lmark.slave_cookie = lmark.slave_cookie + 1
  return slave_id
end

function lmark.saveable_slave_table(slave)
  local saveable = {
    slave_id = slave.slave_id,
    triggers = slave.triggers,
    old_read = slave.old_read
  }
  return saveable
end

function lmark:master_trigger_fn(trigger_name, point, ...)
  local old_trigger = self.slave_table.old_triggers[trigger_name]
  -- Pull the trigger on the master first.
  old_trigger(self, point, ...)

  local slave_points =
    dgn.find_marker_positions_by_prop("slave_id", self.slave_table.slave_id)
  for _, slave_pos in ipairs(slave_points) do
    old_trigger(self, slave_pos, ...)
  end
end

function lmark:master_write(marker, th)
  -- Save the slave table first.
  lmark.marshall_table(th, lmark.saveable_slave_table(self.slave_table))
  self.slave_table.old_write(self, marker, th)
end


function lmark:master_read(marker, th)
  -- Load the slave table.
  local slave_table = lmark.unmarshall_table(th)

  local cookie_number = string.match(slave_table.slave_id, "marker_slave(%d+)")
  -- [ds] Try to avoid reusing the same cookie as one we've reloaded.
  -- This is only necessary to avoid collisions with cookies generated
  -- for future vaults placed on this level (such as by the Trowel
  -- card).
  if cookie_number then
    cookie_number = tonumber(cookie_number)
    if lmark.slave_cookie <= cookie_number then
      lmark.slave_cookie = cookie_number + 1
    end
  end

  -- Call the old read function.
  local newself = slave_table.old_read(self, marker, th)
  -- And redecorate the marker as a master marker.
  return lmark.make_master(newself, slave_table.slave_id,
                           slave_table.triggers)
end

function lmark.make_master(lmarker, slave_id, triggers)
  local old_trigger_map = { }
  for _, trigger_name in ipairs(triggers) do
    old_trigger_map[trigger_name] = lmarker[trigger_name]
    lmarker[trigger_name] =
      function (self, ...)
        return lmark.master_trigger_fn(self, trigger_name, ...)
      end
  end

  lmarker.slave_table = {
    slave_id = slave_id,
    triggers = triggers,
    old_write = lmarker.write,
    old_triggers = old_trigger_map,
    old_read = lmarker.read
  }

  lmarker.write = lmark.master_write
  lmarker.read = lmark.master_read

  return lmarker
end

function lmark.make_slave(slave_id)
  return portal_desc { slave_id = slave_id }
end

function lmark.synchronized_markers(master, ...)
  local first = true
  local slave_id = lmark.next_slave_id()
  local triggers = { ... }
  assert(#triggers > 0,
         "Please provide one or more trigger functions on the master marker")
  return function ()
           if first then
             first = false
             return lmark.make_master(master, slave_id, triggers)
           else
             return lmark.make_slave(slave_id)
           end
         end
end
