#!/usr/bin/env lua
local uloop = require("uloop")
local iwinfo = require("iwinfo")
local uci = require "luci.model.uci".cursor()
local wifi_info = uci:get_all ("wireless")
local json = require "cjson"
local ubus = require("ubus")
local nfs = require "nixio.fs"

local mode_change = false
local times = 1
local channnes = 7
local WIFI_CHANNEL_CHANGE_INTERVAL = ... --500ms
local timer
local timeout_timer --send fail timeout time to restore the mode
local value
local maxtimeout=600000 --ms
local statistics=0

if WIFI_CHANNEL_CHANGE_INTERVAL then
	WIFI_CHANNEL_CHANGE_INTERVAL = tonumber(WIFI_CHANNEL_CHANGE_INTERVAL)
else
	WIFI_CHANNEL_CHANGE_INTERVAL = 500
end

function set_debug(debug)
	DEBUG = debug

	if not debug then
		print = org_print
		return
	end

	io.output("/var/log/channel_change.log")

	function myprint(...)
		local arg = { ... }
		for k, v in pairs(arg) do
			if type(v) == "boolean" then
				if v then
					v = "true"
				else
					v = "false"
				end
			end
			io.write(v)
			io.write("      ")
			io.flush()
		end
		io.write("\n")
	end
	print = myprint
	io.flush()
end


function get_wifi_info(info,key)
	for i,v in pairs(info) do
      if type(v) == "table" then
          get_wifi_info(v,key)
      else
      	if i == key then
      		value = v
        end
      end
    end
    return value
end

function get_wifi_mode()
	return get_wifi_info(wifi_info,"mode")
end

function get_wifi_ifname()
	return get_wifi_info(wifi_info,"ifname")
end

function get_wifi_device()
	return get_wifi_info(wifi_info,"device")
end

function get_wifi_network()
	return get_wifi_info(wifi_info,"network")
end

function set_wifi_mode(to_mode)
	local wifi_mode = get_wifi_mode()
	if wifi_mode and to_mode then
		uci:foreach("wireless", "wifi-iface", function (s)
			if s.mode ~= to_mode then
				uci:set("wireless", s[".name"], "mode", to_mode)
				mode_change = true
			end
		end)	
		uci:save("wireless")
		uci:commit("wireless")
		if mode_change == true then
			os.execute("wifi")
			--sleep for a while
			os.execute("sleep 1")
		end
	end
end

function get_wifi_interface_name()
	local conn = ubus.connect()
	if not conn then
		error("Failed to connect to ubusd")
	end
	local wifi_ifname
	local data = conn:call("iwinfo","devices",{}).devices
	if data then
		wifi_ifname = data[1]
	end
	conn:close()
	return wifi_ifname
end

function set_wifi_channel()
	wifi_info = uci:get_all ("wireless")
	--get the wifi mode
	local wifi_mode = get_wifi_mode()

	--disable auth and stop
	os.execute("/etc/init.d/authd disable")
	os.execute("/etc/init.d/authd stop")
	if wifi_mode ~= "monitor" then
		return
	end

	local wifi_ifname = get_wifi_interface_name() or get_wifi_ifname()
	times = times +1
	local channel
	local htmode
	times = math.modf(math.fmod(times,channnes))
	if times == 0 then
		channel = 1
		htmode = "HT40+"
	elseif times == 1 then
		channel = 1
		htmode = "HT20"
	elseif times == 2 then
		channel = 6
		htmode = "HT40-"
	elseif times == 3 then
		channel = 6
		htmode = "HT20"
	elseif times == 4 then
		channel = 6
		htmode = "HT40+"
	elseif times == 5 then
		channel = 11
		htmode = "HT40-"
	elseif times == 6 then
		channel = 11
		htmode = "HT20"
	--[[elseif times == 7 then
		channel = 8
	elseif times == 8 then
		channel = 9
	elseif times == 9 then
		channel = 10
	elseif times == 10 then
		channel = 11
	elseif times == 11 then
		channel = 12
	elseif times == 12 then
		channel = 13]]--
	end
	if wifi_ifname then
		os.execute("iw dev "..wifi_ifname.." set".." channel "..channel.." "..htmode)
	end
	if channel == 1 or channel ==6 or channel ==11 then
		timer:set(WIFI_CHANNEL_CHANGE_INTERVAL)
	else
		timer:set(WIFI_CHANNEL_CHANGE_INTERVAL)
	end
end

function channel_poll()
	timer = uloop.timer(set_wifi_channel)
	timer:set(WIFI_CHANNEL_CHANGE_INTERVAL)
end

function channel_poll_stop()
	if timer then
		timer:cancel()
	end
end

function file_put(file_path,file_name,type)
	if file_path and file_name then
		local conn = ubus.connect()
		if not conn then
			error("Failed to connect to ubusd")
		end
		print("file_put:",file_path,file_name,type)
		os.execute("ubus call wifispider put '{\"file_path\":"..file_path..",".."file_name"..":"..file_name..",".."type"..":"..type.."}'")
		--os.execute(string.format("ubus call wifispider put \'{\"file_path\":%s,\"file_name\":%s,\"type\":%s}\'",file_path,file_name,type))
		--local res = conn:call("wifispider","put",{file_path = file_path,file_name = file_name,type = type})
		--if res then
		--	print(json.encode(res))
		--end
		conn:close()
	end
end

function wifi_probe_put(file_path,file_name,type)
	if file_path and file_name and type then
		print(file_path,file_name,type)
		wifi_info = uci:get_all ("wireless")
		--judge the the device need to connect to the wirelee of others
		local wifi_network = get_wifi_network()
		if wifi_network~= "lan" or wifi_network ~="lan1" then
			print(wifi_network)
			--stop the timer of channel poll
			channel_poll_stop()
			--set the wifi mode to "sta"
			set_wifi_mode("sta")
			--add a timer to restore the wifi mode
			uloop.timer(function() set_wifi_mode("monitor") channel_poll(); end, maxtimeout)
			--file_put(file_path,file_name,type)
		else
			file_put(file_path,file_name,type)
		end
	end
end

function prepare_send()
	wifi_info = uci:get_all ("wireless")
	--judge the the device need to connect to the wirelee of others
	local wifi_network = get_wifi_network()
	if wifi_network~= "lan" or wifi_network ~="lan1" then
		print(wifi_network)
		--stop the timer of channel poll
		channel_poll_stop()
		--set the wifi mode to "sta"
		set_wifi_mode("sta")
		--restart the dnsmaq
		os.execute("/etc/init.d/dnsmasq restart")
		--add a timer to restore the wifi mode
		uloop.timer(function() set_wifi_mode("monitor") channel_poll(); end, maxtimeout)
	end
end

--wait the file send ok
local wifi_event = {
	wifi_pcap = function(msg)
		statistics = statistics +1
		for k, v in pairs(msg) do
			if tostring(v) =="1" then
				--print("key=" .. k .. " value=" .. tostring(v))
				os.execute("echo "..statistics.." >/tmp/log/wifi_statistics")
				--force send heartbeat once,even not success
				set_wifi_mode("monitor")
				channel_poll()
			end
		end
	end,
}

uloop.init()

local conn = ubus.connect()
if not conn then
	error("Fail to connect to ubus")
end

local wait_sysd = os.execute("ubus wait_for sysd")
if wait_sysd == 0 then
	local moid = conn:call("sysd", "moid", {}).moid
	if moid and moid~= "10000215" then
		--set the wifi config
		set_wifi_mode("monitor")
	end
end
--set_debug(1)
channel_poll()
--disable auth and stop
os.execute("/etc/init.d/authd disable")
os.execute("/etc/init.d/authd stop")
conn:add({
	wifi_probe = {
		put = {
			function(req, msg)
				if msg.file_path ~= nil and msg.file_name ~=nil then
					wifi_probe_put(msg.file_path,msg.file_name,"1")
					conn:reply(req, { msg="ok"})
				else
					conn:reply(req, { msg="parameter error!" })
				end
			end, {file_path = ubus.STRING ,file_name = ubus.STRING}
		},

		prepare = {
			function (req, msg)
				prepare_send()
			end,
			{ }
		},
	}
})
conn:listen(wifi_event)
uloop.run()
