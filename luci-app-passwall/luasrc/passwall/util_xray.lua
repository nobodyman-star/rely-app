module("luci.passwall.util_xray", package.seeall)
local api = require "luci.passwall.api"
local uci = api.uci
local sys = api.sys
local jsonc = api.jsonc
local appname = "passwall"
local fs = api.fs

local new_port

local function get_new_port()
	if new_port then
		new_port = tonumber(sys.exec(string.format("echo -n $(/usr/share/%s/app.sh get_new_port %s tcp)", appname, new_port + 1)))
	else
		new_port = tonumber(sys.exec(string.format("echo -n $(/usr/share/%s/app.sh get_new_port auto tcp)", appname)))
	end
	return new_port
end

local function get_noise_packets()
	local noises = {}
	uci:foreach(appname, "xray_noise_packets", function(n)
		local noise = (n.enabled == "1") and {
			type = n.type,
			packet = n.packet,
			delay = string.find(n.delay, "-") and n.delay or tonumber(n.delay)
		} or nil
		table.insert(noises, noise)
	end)
	if #noises == 0 then noises = nil end
	return noises
end

local function get_domain_excluded()
	local path = string.format("/usr/share/%s/rules/domains_excluded", appname)
	local content = fs.readfile(path)
	if not content then return nil end
	local hosts = {}
	string.gsub(content, '[^' .. "\n" .. ']+', function(w)
		local s = w:gsub("^%s*(.-)%s*$", "%1") -- Trim
		if s == "" then return end
		if s:find("#") and s:find("#") == 1 then return end
		if not s:find("#") or s:find("#") ~= 1 then table.insert(hosts, s) end
	end)
	if #hosts == 0 then hosts = nil end
	return hosts
end

function gen_outbound(flag, node, tag, proxy_table)
	local result = nil
	if node and node ~= "nil" then
		local node_id = node[".name"]
		if tag == nil then
			tag = node_id
		end

		local proxy_tag = nil
		local fragment = nil
		local noise = nil
		if proxy_table ~= nil and type(proxy_table) == "table" then
			proxy_tag = proxy_table.tag or nil
			fragment = proxy_table.fragment or nil
			noise = proxy_table.noise or nil
		end

		if node.type ~= "Xray" then
			if node.type == "Socks" then
				node.protocol = "socks"
				node.transport = "tcp"
			else
				local relay_port = node.port
				new_port = get_new_port()
				local config_file = string.format("%s_%s_%s.json", flag, tag, new_port)
				if tag and node_id and tag ~= node_id then
					config_file = string.format("%s_%s_%s_%s.json", flag, tag, node_id, new_port)
				end
				sys.call(string.format('/usr/share/%s/app.sh run_socks "%s"> /dev/null',
					appname,
					string.format("flag=%s node=%s bind=%s socks_port=%s config_file=%s relay_port=%s",
						new_port, --flag
						node_id, --node
						"127.0.0.1", --bind
						new_port, --socks port
						config_file, --config file
						(proxy_tag and proxy_tag ~= "nil" and relay_port) and tostring(relay_port) or "" --relay port
					)
				))
				node = {}
				node.protocol = "socks"
				node.transport = "tcp"
				node.address = "127.0.0.1"
				node.port = new_port
			end
			node.stream_security = "none"
		else
			if node.flow == "xtls-rprx-vision" then
			else
				if proxy_tag and proxy_tag ~= "nil" then
					node.proxySettings = {
						tag = proxy_tag,
						transportLayer = true
					}
				end
			end
		end

		if node.type == "Xray" then
			if node.tls and node.tls == "1" then
				node.stream_security = "tls"
				if node.type == "Xray" and node.reality and node.reality == "1" then
					node.stream_security = "reality"
				end
			end
		end

		if node.type == "Xray" and node.transport == "splithttp" then
			if node.xhttp_download_tls and node.xhttp_download_tls == "1" then
				node.xhttp_download_stream_security = "tls"
				if node.xhttp_download_reality and node.xhttp_download_reality == "1" then
					node.xhttp_download_stream_security = "reality"
				end
			end
		end

		if node.protocol == "wireguard" and node.wireguard_reserved then
			local bytes = {}
			if not node.wireguard_reserved:match("[^%d,]+") then
				node.wireguard_reserved:gsub("%d+", function(b)
					bytes[#bytes + 1] = tonumber(b)
				end)
			else
				local result = api.bin.b64decode(node.wireguard_reserved)
				for i = 1, #result do
					bytes[i] = result:byte(i)
				end
			end
			node.wireguard_reserved = #bytes > 0 and bytes or nil
		end

		result = {
			_id = node_id,
			_flag = flag,
			_flag_proxy_tag = proxy_tag,
			tag = tag,
			proxySettings = node.proxySettings or nil,
			protocol = node.protocol,
			mux = {
				enabled = (node.mux == "1" or node.xmux == "1") and true or false,
				concurrency = (node.mux == "1" and ((node.mux_concurrency) and tonumber(node.mux_concurrency) or 8)) or ((node.xmux == "1") and -1) or nil,
				xudpConcurrency = (node.xmux == "1" and ((node.xudp_concurrency) and tonumber(node.xudp_concurrency) or 8)) or nil
			} or nil,
			-- 底层传输配置
			streamSettings = (node.streamSettings or node.protocol == "vmess" or node.protocol == "vless" or node.protocol == "socks" or node.protocol == "shadowsocks" or node.protocol == "trojan") and {
				sockopt = {
					mark = 255,
					tcpMptcp = (node.tcpMptcp == "1") and true or nil,
					tcpNoDelay = (node.tcpNoDelay == "1") and true or nil,
					dialerProxy = (fragment or noise) and "dialerproxy" or nil
				},
				network = node.transport,
				security = node.stream_security,
				tlsSettings = (node.stream_security == "tls") and {
					serverName = node.tls_serverName,
					allowInsecure = (node.tls_allowInsecure == "1") and true or false,
					fingerprint = (node.type == "Xray" and node.utls == "1" and node.fingerprint and node.fingerprint ~= "") and node.fingerprint or nil
				} or nil,
				realitySettings = (node.stream_security == "reality") and {
					serverName = node.tls_serverName,
					publicKey = node.reality_publicKey,
					shortId = node.reality_shortId or "",
					spiderX = node.reality_spiderX or "/",
					fingerprint = (node.type == "Xray" and node.fingerprint and node.fingerprint ~= "") and node.fingerprint or "chrome"
				} or nil,
				tcpSettings = (node.transport == "tcp" and node.protocol ~= "socks") and {
					header = {
						type = node.tcp_guise or "none",
						request = (node.tcp_guise == "http") and {
							path = node.tcp_guise_http_path or {"/"},
							headers = {
								Host = node.tcp_guise_http_host or {}
							}
						} or nil
					}
				} or nil,
				kcpSettings = (node.transport == "mkcp") and {
					mtu = tonumber(node.mkcp_mtu),
					tti = tonumber(node.mkcp_tti),
					uplinkCapacity = tonumber(node.mkcp_uplinkCapacity),
					downlinkCapacity = tonumber(node.mkcp_downlinkCapacity),
					congestion = (node.mkcp_congestion == "1") and true or false,
					readBufferSize = tonumber(node.mkcp_readBufferSize),
					writeBufferSize = tonumber(node.mkcp_writeBufferSize),
					seed = (node.mkcp_seed and node.mkcp_seed ~= "") and node.mkcp_seed or nil,
					header = {type = node.mkcp_guise}
				} or nil,
				wsSettings = (node.transport == "ws") and {
					path = node.ws_path or "/",
					headers = (node.ws_host ~= nil) and
						{Host = node.ws_host} or nil,
					maxEarlyData = tonumber(node.ws_maxEarlyData) or nil,
					earlyDataHeaderName = (node.ws_earlyDataHeaderName) and node.ws_earlyDataHeaderName or nil
				} or nil,
				httpSettings = (node.transport == "h2") and {
					path = node.h2_path or "/",
					host = node.h2_host,
					read_idle_timeout = tonumber(node.h2_read_idle_timeout) or nil,
					health_check_timeout = tonumber(node.h2_health_check_timeout) or nil
				} or nil,
				dsSettings = (node.transport == "ds") and
					{path = node.ds_path} or nil,
				quicSettings = (node.transport == "quic") and {
					security = node.quic_security,
					key = node.quic_key,
					header = {type = node.quic_guise}
				} or nil,
				grpcSettings = (node.transport == "grpc") and {
					serviceName = node.grpc_serviceName,
					multiMode = (node.grpc_mode == "multi") and true or nil,
					idle_timeout = tonumber(node.grpc_idle_timeout) or nil,
					health_check_timeout = tonumber(node.grpc_health_check_timeout) or nil,
					permit_without_stream = (node.grpc_permit_without_stream == "1") and true or nil,
					initial_windows_size = tonumber(node.grpc_initial_windows_size) or nil
				} or nil,
				httpupgradeSettings = (node.transport == "httpupgrade") and {
					path = node.httpupgrade_path or "/",
					host = node.httpupgrade_host
				} or nil,
				splithttpSettings = (node.transport == "splithttp") and {
					path = node.splithttp_path or "/",
					host = node.splithttp_host,
					downloadSettings = (node.xhttp_download == "1") and {
						address = node.xhttp_download_address,
						port = tonumber(node.xhttp_download_port),
						network = "xhttp",
						xhttpSettings = {
							path = node.xhttp_download_path,
							host = node.xhttp_download_host,
						},
						security = node.xhttp_download_stream_security,
						tlsSettings = (node.xhttp_download_stream_security == "tls") and {
							serverName = node.xhttp_download_tls_serverName,
							allowInsecure = false,
							fingerprint = (node.xhttp_download_utls == "1" and
								node.xhttp_download_fingerprint and
								node.xhttp_download_fingerprint ~= "") and node.xhttp_download_fingerprint or nil
						} or nil,
						realitySettings = (node.xhttp_download_stream_security == "reality") and {
							serverName = node.xhttp_download_tls_serverName,
							publicKey = node.xhttp_download_reality_publicKey,
							shortId = node.xhttp_download_reality_shortId or "",
							spiderX = node.xhttp_download_reality_spiderX or "/",
							fingerprint = (
								node.xhttp_download_fingerprint and
								node.xhttp_download_fingerprint ~= "") and node.xhttp_download_fingerprint or nil
						} or nil,
					} or nil
				} or nil,
			} or nil,
			settings = {
				vnext = (node.protocol == "vmess" or node.protocol == "vless") and {
					{
						address = node.address,
						port = tonumber(node.port),
						users = {
							{
								id = node.uuid,
								level = 0,
								security = (node.protocol == "vmess") and node.security or nil,
								encryption = node.encryption or "none",
								flow = (node.protocol == "vless" and node.tls == "1" and node.transport == "tcp" and node.flow and node.flow ~= "") and node.flow or nil
							}
						}
					}
				} or nil,
				servers = (node.protocol == "socks" or node.protocol == "http" or node.protocol == "shadowsocks" or node.protocol == "trojan") and {
					{
						address = node.address,
						port = tonumber(node.port),
						method = node.method or nil,
						ivCheck = (node.protocol == "shadowsocks") and node.iv_check == "1" or nil,
						uot = (node.protocol == "shadowsocks") and node.uot == "1" or nil,
						password = node.password or "",
						users = (node.username and node.password) and {
							{
								user = node.username,
								pass = node.password
							}
						} or nil
					}
				} or nil,
				address = (node.protocol == "wireguard" and node.wireguard_local_address) and node.wireguard_local_address or nil,
				secretKey = (node.protocol == "wireguard") and node.wireguard_secret_key or nil,
				peers = (node.protocol == "wireguard") and {
					{
						publicKey = node.wireguard_public_key,
						endpoint = node.address .. ":" .. node.port,
						preSharedKey = node.wireguard_preSharedKey,
						keepAlive = node.wireguard_keepAlive and tonumber(node.wireguard_keepAlive) or nil
					}
				} or nil,
				mtu = (node.protocol == "wireguard" and node.wireguard_mtu) and tonumber(node.wireguard_mtu) or nil,
				reserved = (node.protocol == "wireguard" and node.wireguard_reserved) and node.wireguard_reserved or nil
			}
		}

		if node.protocol == "wireguard" then
			result.settings.kernelMode = false
		end

		local alpn = {}
		if node.alpn and node.alpn ~= "default" then
			string.gsub(node.alpn, '[^' .. "," .. ']+', function(w)
				table.insert(alpn, w)
			end)
		end
		if alpn and #alpn > 0 then
			if result.streamSettings.tlsSettings then
				result.streamSettings.tlsSettings.alpn = alpn
			end
		end

		local xmux = {}
		if (node.xhttp_xmux == "1") then
			xmux.maxConcurrency = node.maxConcurrency and (string.find(node.maxConcurrency, "-") and node.maxConcurrency or tonumber(node.maxConcurrency)) or 0
			xmux.maxConnections = node.maxConnections and (string.find(node.maxConnections, "-") and node.maxConnections or tonumber(node.maxConnections)) or 0
			xmux.cMaxReuseTimes = node.cMaxReuseTimes and (string.find(node.cMaxReuseTimes, "-") and node.cMaxReuseTimes or tonumber(node.cMaxReuseTimes)) or 0
			xmux.cMaxLifetimeMs = node.cMaxLifetimeMs and (string.find(node.cMaxLifetimeMs, "-") and node.cMaxLifetimeMs or tonumber(node.cMaxLifetimeMs)) or 0
			if result.streamSettings.splithttpSettings then
				result.streamSettings.splithttpSettings.xmux = xmux
			end
		end

		local xmux_download = {}
		if (node.xhttp_download_xmux == "1") then
			xmux_download.maxConcurrency = node.download_maxConcurrency and (string.find(node.download_maxConcurrency, "-") and node.download_maxConcurrency or tonumber(node.download_maxConcurrency)) or 0
			xmux_download.maxConnections = node.download_maxConnections and (string.find(node.download_maxConnections, "-") and node.download_maxConnections or tonumber(node.download_maxConnections)) or 0
			xmux_download.cMaxReuseTimes = node.download_cMaxReuseTimes and (string.find(node.download_cMaxReuseTimes, "-") and node.download_cMaxReuseTimes or tonumber(node.download_cMaxReuseTimes)) or 0
			xmux_download.cMaxLifetimeMs = node.download_cMaxLifetimeMs and (string.find(node.download_cMaxLifetimeMs, "-") and node.download_cMaxLifetimeMs or tonumber(node.download_cMaxLifetimeMs)) or 0
			if result.streamSettings.splithttpSettings.downloadSettings.xhttpSettings then
				result.streamSettings.splithttpSettings.downloadSettings.xhttpSettings.xmux = xmux_download
			end
		end

	end
	return result
end

function gen_config_server(node)
	local settings = nil
	local routing = nil
	local outbounds = {
		{ protocol = "freedom", tag = "direct" }, { protocol = "blackhole", tag = "blocked" }
	}

	if node.protocol == "vmess" or node.protocol == "vless" then
		if node.uuid then
			local clients = {}
			for i = 1, #node.uuid do
				clients[i] = {
					id = node.uuid[i],
					flow = ("vless" == node.protocol and "1" == node.tls and "tcp" == node.transport and node.flow and node.flow ~= "") and node.flow or nil
				}
			end
			settings = {
				clients = clients,
				decryption = node.decryption or "none"
			}
		end
	elseif node.protocol == "socks" then
		settings = {
			udp = ("1" == node.udp_forward) and true or false,
			auth = ("1" == node.auth) and "password" or "noauth",
			accounts = ("1" == node.auth) and {
				{
					user = node.username,
					pass = node.password
				}
			} or nil
		}
	elseif node.protocol == "http" then
		settings = {
			allowTransparent = false,
			accounts = ("1" == node.auth) and {
				{
					user = node.username,
					pass = node.password
				}
			} or nil
		}
		node.transport = "tcp"
		node.tcp_guise = "none"
	elseif node.protocol == "shadowsocks" then
		settings = {
			method = node.method,
			password = node.password,
			ivCheck = ("1" == node.iv_check) and true or false,
			network = node.ss_network or "TCP,UDP"
		}
	elseif node.protocol == "trojan" then
		if node.uuid then
			local clients = {}
			for i = 1, #node.uuid do
				clients[i] = {
					password = node.uuid[i],
				}
			end
			settings = {
				clients = clients
			}
		end
	elseif node.protocol == "dokodemo-door" then
		settings = {
			network = node.d_protocol,
			address = node.d_address,
			port = tonumber(node.d_port)
		}
	end

	if node.fallback and node.fallback == "1" then
		local fallbacks = {}
		for i = 1, #node.fallback_list do
			local fallbackStr = node.fallback_list[i]
			if fallbackStr then
				local tmp = {}
				string.gsub(fallbackStr, '[^' .. "," .. ']+', function(w)
					table.insert(tmp, w)
				end)
				local dest = tmp[1] or ""
				local path = tmp[2]
				if dest:find("%.") then
				else
					dest = tonumber(dest)
				end
				fallbacks[i] = {
					path = path,
					dest = dest,
					xver = 1
				}
			end
		end
		settings.fallbacks = fallbacks
	end

	routing = {
		domainStrategy = "IPOnDemand",
		rules = {
			{
				ip = {"10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"},
				outboundTag = (node.accept_lan == nil or node.accept_lan == "0") and "blocked" or "direct"
			}
		}
	}

	if node.outbound_node and node.outbound_node ~= "nil" then
		local outbound = nil
		if node.outbound_node == "_iface" and node.outbound_node_iface then
			outbound = {
				protocol = "freedom",
				tag = "outbound",
				streamSettings = {
					sockopt = {
						mark = 255,
						interface = node.outbound_node_iface
					}
				}
			}
			sys.call("mkdir -p /tmp/etc/passwall/iface && touch /tmp/etc/passwall/iface/" .. node.outbound_node_iface)
		else
			local outbound_node_t = uci:get_all("passwall", node.outbound_node)
			if node.outbound_node == "_socks" or node.outbound_node == "_http" then
				outbound_node_t = {
					type = node.type,
					protocol = node.outbound_node:gsub("_", ""),
					transport = "tcp",
					address = node.outbound_node_address,
					port = node.outbound_node_port,
					username = (node.outbound_node_username and node.outbound_node_username ~= "") and node.outbound_node_username or nil,
					password = (node.outbound_node_password and node.outbound_node_password ~= "") and node.outbound_node_password or nil,
				}
			end
			outbound = require("luci.passwall.util_xray").gen_outbound(nil, outbound_node_t, "outbound")
		end
		if outbound then
			table.insert(outbounds, 1, outbound)
		end
	end

	local config = {
		log = {
			-- error = "/tmp/etc/passwall_server/log/" .. user[".name"] .. ".log",
			loglevel = ("1" == node.log) and node.loglevel or "none"
		},
		-- 传入连接
		inbounds = {
			{
				listen = (node.bind_local == "1") and "127.0.0.1" or nil,
				port = tonumber(node.port),
				protocol = node.protocol,
				settings = settings,
				streamSettings = {
					network = node.transport,
					security = "none",
					tlsSettings = ("1" == node.tls) and {
						disableSystemRoot = false,
						certificates = {
							{
								certificateFile = node.tls_certificateFile,
								keyFile = node.tls_keyFile
							}
						}
					} or nil,
					tcpSettings = (node.transport == "tcp") and {
						header = {
							type = node.tcp_guise,
							request = (node.tcp_guise == "http") and {
								path = node.tcp_guise_http_path or {"/"},
								headers = {
									Host = node.tcp_guise_http_host or {}
								}
							} or nil
						}
					} or nil,
					kcpSettings = (node.transport == "mkcp") and {
						mtu = tonumber(node.mkcp_mtu),
						tti = tonumber(node.mkcp_tti),
						uplinkCapacity = tonumber(node.mkcp_uplinkCapacity),
						downlinkCapacity = tonumber(node.mkcp_downlinkCapacity),
						congestion = (node.mkcp_congestion == "1") and true or false,
						readBufferSize = tonumber(node.mkcp_readBufferSize),
						writeBufferSize = tonumber(node.mkcp_writeBufferSize),
						seed = (node.mkcp_seed and node.mkcp_seed ~= "") and node.mkcp_seed or nil,
						header = {type = node.mkcp_guise}
					} or nil,
					wsSettings = (node.transport == "ws") and {
						headers = (node.ws_host) and {Host = node.ws_host} or nil,
						path = node.ws_path
					} or nil,
					httpSettings = (node.transport == "h2") and {
						path = node.h2_path, host = node.h2_host
					} or nil,
					dsSettings = (node.transport == "ds") and {
						path = node.ds_path
					} or nil,
					quicSettings = (node.transport == "quic") and {
						security = node.quic_security,
						key = node.quic_key,
						header = {type = node.quic_guise}
					} or nil,
					grpcSettings = (node.transport == "grpc") and {
						serviceName = node.grpc_serviceName
					} or nil,
					httpupgradeSettings = (node.transport == "httpupgrade") and {
						path = node.httpupgrade_path or "/",
						host = node.httpupgrade_host
					} or nil,
					splithttpSettings = (node.transport == "splithttp") and {
						path = node.splithttp_path or "/",
						host = node.splithttp_host
					} or nil,
					sockopt = {
						acceptProxyProtocol = (node.acceptProxyProtocol and node.acceptProxyProtocol == "1") and true or false
					}
				}
			}
		},
		-- 传出连接
		outbounds = outbounds,
		routing = routing
	}

	local alpn = {}
	if node.alpn then
		string.gsub(node.alpn, '[^' .. "," .. ']+', function(w)
			table.insert(alpn, w)
		end)
	end
	if alpn and #alpn > 0 then
		if config.inbounds[1].streamSettings.tlsSettings then
			config.inbounds[1].streamSettings.tlsSettings.alpn = alpn
		end
	end

	if "1" == node.tls then
		config.inbounds[1].streamSettings.security = "tls"
		if "1" == node.reality then
			config.inbounds[1].streamSettings.tlsSettings = nil
			config.inbounds[1].streamSettings.security = "reality"
			config.inbounds[1].streamSettings.realitySettings = {
				show = false,
				dest = node.reality_dest,
				serverNames = {
					node.reality_serverNames
				},
				privateKey = node.reality_private_key,
				shortIds = node.reality_shortId or ""
			} or nil
		end
	end

	return config
end

function gen_config(var)
	local flag = var["-flag"]
	local node_id = var["-node"]
	local server_host = var["-server_host"]
	local server_port = var["-server_port"]
	local tcp_proxy_way = var["-tcp_proxy_way"] or "redirect"
	local tcp_redir_port = var["-tcp_redir_port"]
	local udp_redir_port = var["-udp_redir_port"]
	local local_socks_address = var["-local_socks_address"] or "0.0.0.0"
	local local_socks_port = var["-local_socks_port"]
	local local_socks_username = var["-local_socks_username"]
	local local_socks_password = var["-local_socks_password"]
	local local_http_address = var["-local_http_address"] or "0.0.0.0"
	local local_http_port = var["-local_http_port"]
	local local_http_username = var["-local_http_username"]
	local local_http_password = var["-local_http_password"]
	local dns_listen_port = var["-dns_listen_port"]
	local dns_query_strategy = var["-dns_query_strategy"]
	local remote_dns_tcp_server = var["-remote_dns_tcp_server"]
	local remote_dns_tcp_port = var["-remote_dns_tcp_port"]
	local remote_dns_doh_url = var["-remote_dns_doh_url"]
	local remote_dns_doh_host = var["-remote_dns_doh_host"]
	local remote_dns_doh_ip = var["-remote_dns_doh_ip"]
	local remote_dns_doh_port = var["-remote_dns_doh_port"]
	local dns_cache = var["-dns_cache"]
	local dns_client_ip = var["-dns_client_ip"]
	local dns_socks_address = var["-dns_socks_address"]
	local dns_socks_port = var["-dns_socks_port"]
	local loglevel = var["-loglevel"] or "warning"

	local dns = nil
	local routing = nil
	local observatory = nil
	local inbounds = {}
	local outbounds = {}
	local COMMON = {}

	local xray_settings = uci:get_all(appname, "@global_xray[0]") or {}

	if node_id then
		local node = uci:get_all(appname, node_id)
		local balancers = {}
		local rules = {}
		if node then
			if server_host and server_port then
				node.address = server_host
				node.port = server_port
			end
		end
		if local_socks_port then
			local inbound = {
				tag = "socks-in",
				listen = local_socks_address,
				port = tonumber(local_socks_port),
				protocol = "socks",
				settings = {auth = "noauth", udp = true},
				sniffing = {enabled = true, destOverride = {"http", "tls", "quic"}}
			}
			if local_socks_username and local_socks_password and local_socks_username ~= "" and local_socks_password ~= "" then
				inbound.settings.auth = "password"
				inbound.settings.accounts = {
					{
						user = local_socks_username,
						pass = local_socks_password
					}
				}
			end
			table.insert(inbounds, inbound)
		end
		if local_http_port then
			local inbound = {
				listen = local_http_address,
				port = tonumber(local_http_port),
				protocol = "http",
				settings = {allowTransparent = false}
			}
			if local_http_username and local_http_password and local_http_username ~= "" and local_http_password ~= "" then
				inbound.settings.accounts = {
					{
						user = local_http_username,
						pass = local_http_password
					}
				}
			end
			table.insert(inbounds, inbound)
		end

		if tcp_redir_port or udp_redir_port then
			local inbound = {
				protocol = "dokodemo-door",
				settings = {network = "tcp,udp", followRedirect = true},
				streamSettings = {sockopt = {tproxy = "tproxy"}},
				sniffing = {
					enabled = xray_settings.sniffing_override_dest == "1" or node.protocol == "_shunt",
					destOverride = {"http", "tls", "quic"},
					metadataOnly = false,
					routeOnly = node.protocol == "_shunt" and xray_settings.sniffing_override_dest ~= "1" or nil,
					domainsExcluded = xray_settings.sniffing_override_dest == "1" and get_domain_excluded() or nil
				}
			}

			if tcp_redir_port then
				local tcp_inbound = api.clone(inbound)
				tcp_inbound.tag = "tcp_redir"
				tcp_inbound.settings.network = "tcp"
				tcp_inbound.port = tonumber(tcp_redir_port)
				tcp_inbound.streamSettings.sockopt.tproxy = tcp_proxy_way
				table.insert(inbounds, tcp_inbound)
			end

			if udp_redir_port then
				local udp_inbound = api.clone(inbound)
				udp_inbound.tag = "udp_redir"
				udp_inbound.settings.network = "udp"
				udp_inbound.port = tonumber(udp_redir_port)
				table.insert(inbounds, udp_inbound)
			end
		end

		local function gen_loopback(outbound_tag, loopback_dst)
			if not outbound_tag or outbound_tag == "" then return nil end
			local inbound_tag = loopback_dst and "lo-to-" .. loopback_dst or outbound_tag .. "-lo"
			table.insert(outbounds, {
				protocol = "loopback",
				tag = outbound_tag,
				settings = { inboundTag = inbound_tag }
			})
			return inbound_tag
		end

		local function gen_balancer(_node, loopback_tag)
			local balancer_id = _node[".name"]
			local balancer_tag = "balancer-" .. balancer_id
			local loopback_dst = balancer_id -- route destination for the loopback outbound
			if not loopback_tag or loopback_tag == "" then loopback_tag = balancer_id end
			-- existing balancer
			for _, v in ipairs(balancers) do
				if v.tag == balancer_tag then
					gen_loopback(loopback_tag, loopback_dst)
					return balancer_tag
				end
			end
			-- new balancer
			local blc_nodes = _node.balancing_node
			local length = #blc_nodes
			local valid_nodes = {}
			for i = 1, length do
				local blc_node_id = blc_nodes[i]
				local blc_node_tag = "blc-" .. blc_node_id
				local is_new_blc_node = true
				for _, outbound in ipairs(outbounds) do
					if outbound.tag == blc_node_tag then
						is_new_blc_node = false
						valid_nodes[#valid_nodes + 1] = blc_node_tag
						break
					end
				end
				if is_new_blc_node then
					local blc_node = uci:get_all(appname, blc_node_id)
					local outbound = gen_outbound(flag, blc_node, blc_node_tag, { fragment = xray_settings.fragment == "1" or nil, noise = xray_settings.noise == "1" or nil })
					if outbound then
						outbound.tag = outbound.tag .. ":" .. blc_node.remarks
						table.insert(outbounds, outbound)
						valid_nodes[#valid_nodes + 1] = blc_node_tag
					end
				end
			end
			if #valid_nodes == 0 then return nil end

			-- fallback node
			local fallback_node_id = _node.fallback_node
			if fallback_node_id == "" then fallback_node_id = nil end
			if fallback_node_id then
				local is_new_node = true
				for _, outbound in ipairs(outbounds) do
					if outbound.tag == fallback_node_id then
						is_new_node = false
						break
					end
				end
				if is_new_node then
					local fallback_node = uci:get_all(appname, fallback_node_id)
					if fallback_node.protocol ~= "_balancing" then
						local outbound = gen_outbound(flag, fallback_node, fallback_node_id, { fragment = xray_settings.fragment == "1" or nil, noise = xray_settings.noise == "1" or nil })
						if outbound then
							outbound.tag = outbound.tag .. ":" .. fallback_node.remarks
							table.insert(outbounds, outbound)
						else
							fallback_node_id = nil
						end
					else
						if not gen_balancer(fallback_node) then
							fallback_node_id = nil
						end
					end
				end
			end
			table.insert(balancers, {
				tag = balancer_tag,
				selector = valid_nodes,
				fallbackTag = fallback_node_id,
				strategy = { type = _node.balancingStrategy or "random" }
			})
			if _node.balancingStrategy == "leastPing" or fallback_node_id then
				if not observatory then
					observatory = {
						subjectSelector = { "blc-" },
						probeUrl = _node.useCustomProbeUrl and _node.probeUrl or nil,
						probeInterval = _node.probeInterval or "1m",
						enableConcurrency = true
					}
				end
			end
			local inbound_tag = gen_loopback(loopback_tag, loopback_dst)
			table.insert(rules, { inboundTag = { inbound_tag }, balancerTag = balancer_tag })
			return balancer_tag
		end

		local function set_outbound_detour(node, outbound, outbounds_table, shunt_rule_name)
			if not node or not outbound or not outbounds_table then return nil end
			local default_out_tag = outbound.tag

			if node.to_node then
				local to_node = uci:get_all(appname, node.to_node)
				if to_node then
					local to_outbound = gen_outbound(nil, to_node)
					if to_outbound then
						if shunt_rule_name then
							to_outbound.tag = outbound.tag
							outbound.tag = node[".name"]
						else
							to_outbound.tag = outbound.tag .. " -> " .. to_outbound.tag
						end

						to_outbound.proxySettings = {
							tag = outbound.tag,
							transportLayer = true
						}
						table.insert(outbounds_table, to_outbound)
						default_out_tag = to_outbound.tag
					end
				end
			end
			return default_out_tag
		end

		if node.protocol == "_shunt" then
			local preproxy_rule_name = node.preproxy_enabled == "1" and "main" or nil
			local preproxy_tag = preproxy_rule_name
			local preproxy_node_id = preproxy_rule_name and node["main_node"] or nil
			local preproxy_outbound_tag, preproxy_balancer_tag
			local preproxy_nodes

			local function gen_shunt_node(rule_name, _node_id)
				if not rule_name then return nil, nil end
				if not _node_id then
					_node_id = node[rule_name] or nil
					if not _node_id then return nil, nil end
				end
				if _node_id == "_direct" then
					return "direct", nil
				elseif _node_id == "_blackhole" then
					return "blackhole", nil
				elseif _node_id == "_default" then
					return "default", nil
				elseif _node_id:find("Socks_") then
					local socks_id = _node_id:sub(1 + #"Socks_")
					local socks_node = uci:get_all(appname, socks_id) or nil
					local socks_tag
					if socks_node then
						local _node = {
							type = "Xray",
							protocol = "socks",
							address = "127.0.0.1",
							port = socks_node.port,
							transport = "tcp",
							stream_security = "none"
						}
						local outbound = gen_outbound(flag, _node, rule_name)
						if outbound then
							table.insert(outbounds, outbound)
							socks_tag = outbound.tag
						end
					end
					return socks_tag, nil
				end

				local _node = uci:get_all(appname, _node_id)
				if not _node then return nil, nil end

				if api.is_normal_node(_node) then
					local use_proxy = preproxy_tag and node[rule_name .. "_proxy_tag"] == preproxy_rule_name and _node_id ~= preproxy_node_id
					if use_proxy and preproxy_balancer_tag and preproxy_nodes[_node_id] then use_proxy = false end
					local copied_outbound
					for index, value in ipairs(outbounds) do
						if value["_id"] == _node_id and value["_flag_proxy_tag"] == (use_proxy and preproxy_tag or nil) then
							copied_outbound = api.clone(value)
							break
						end
					end
					if copied_outbound then
						copied_outbound.tag = rule_name
						table.insert(outbounds, copied_outbound)
						return copied_outbound.tag, nil
					end
					--new outbound
					if use_proxy and (_node.type ~= "Xray" or _node.flow == "xtls-rprx-vision") then
						new_port = get_new_port()
						table.insert(inbounds, {
							tag = "proxy_" .. rule_name,
							listen = "127.0.0.1",
							port = new_port,
							protocol = "dokodemo-door",
							settings = {network = "tcp,udp", address = _node.address, port = tonumber(_node.port)}
						})
						if _node.tls_serverName == nil then
							_node.tls_serverName = _node.address
						end
						_node.address = "127.0.0.1"
						_node.port = new_port
						table.insert(rules, 1, {
							inboundTag = {"proxy_" .. rule_name},
							outboundTag = not preproxy_balancer_tag and preproxy_tag or nil,
							balancerTag = preproxy_balancer_tag
						})
					end
					local proxy_table = {
						tag = use_proxy and preproxy_tag or nil
					}
					if not proxy_table.tag then
						if xray_settings.fragment == "1" then
							proxy_table.fragment = true
						end
						if xray_settings.noise == "1" then
							proxy_table.noise = true
						end
					end
					local outbound = gen_outbound(flag, _node, rule_name, proxy_table)
					local outbound_tag
					if outbound then
						outbound.tag = outbound.tag .. ":" .. _node.remarks
						outbound_tag = set_outbound_detour(_node, outbound, outbounds, rule_name)
						if rule_name == "default" then
							table.insert(outbounds, 1, outbound)
						else
							table.insert(outbounds, outbound)
						end
					end
					return outbound_tag, nil
				elseif _node.protocol == "_balancing" then
					return nil, gen_balancer(_node, rule_name)
				elseif _node.protocol == "_iface" then
					if _node.iface then
						local outbound = {
							protocol = "freedom",
							tag = rule_name,
							streamSettings = {
								sockopt = {
									mark = 255,
									interface = _node.iface
								}
							}
						}
						table.insert(outbounds, outbound)
						sys.call("touch /tmp/etc/passwall/iface/" .. _node.iface)
						return outbound.tag, nil
					end
				end
			end

			if preproxy_tag and preproxy_node_id then
				preproxy_outbound_tag, preproxy_balancer_tag = gen_shunt_node(preproxy_rule_name, preproxy_node_id)
				if preproxy_balancer_tag then
					local _node_id = preproxy_node_id
					preproxy_nodes = {}
					while _node_id do
						_node = uci:get_all(appname, _node_id)
						if not _node then break end
						if _node.protocol ~= "_balancing" then
							preproxy_nodes[_node_id] = true
							break
						end
						local _blc_nodes = _node.balancing_node
						for i = 1, #_blc_nodes do preproxy_nodes[_blc_nodes[i]] = true end
						_node_id = _node.fallback_node
					end
				else
					preproxy_tag = preproxy_outbound_tag
				end
			end
			--default_node
			local default_node_id = node.default_node or "_direct"
			local default_outbound_tag, default_balancer_tag = gen_shunt_node("default", default_node_id)
			COMMON.default_outbound_tag = default_outbound_tag
			COMMON.default_balancer_tag = default_balancer_tag
			--shunt rule
			uci:foreach(appname, "shunt_rules", function(e)
				local outbound_tag, balancer_tag = gen_shunt_node(e[".name"])
				if outbound_tag or balancer_tag and e.remarks then
					if outbound_tag == "default" then
						outbound_tag = default_outbound_tag
						balancer_tag = default_balancer_tag
					end
					local protocols = nil
					if e["protocol"] and e["protocol"] ~= "" then
						protocols = {}
						string.gsub(e["protocol"], '[^' .. " " .. ']+', function(w)
							table.insert(protocols, w)
						end)
					end
					local inbound_tag = nil
					if e["inbound"] and e["inbound"] ~= "" then
						inbound_tag = {}
						if e["inbound"]:find("tproxy") then
							if tcp_redir_port then
								table.insert(inbound_tag, "tcp_redir")
							end
							if udp_redir_port then
								table.insert(inbound_tag, "udp_redir")
							end
						end
						if e["inbound"]:find("socks") then
							if local_socks_port then
								table.insert(inbound_tag, "socks-in")
							end
						end
					end
					local domains = nil
					if e.domain_list then
						domains = {}
						string.gsub(e.domain_list, '[^' .. "\r\n" .. ']+', function(w)
							if w:find("#") == 1 then return end
							table.insert(domains, w)
						end)
						if #domains == 0 then domains = nil end
					end
					local ip = nil
					if e.ip_list then
						ip = {}
						string.gsub(e.ip_list, '[^' .. "\r\n" .. ']+', function(w)
							if w:find("#") == 1 then return end
							table.insert(ip, w)
						end)
						if #ip == 0 then ip = nil end
					end
					local source = nil
					if e.source then
						source = {}
						string.gsub(e.source, '[^' .. " " .. ']+', function(w)
							table.insert(source, w)
						end)
					end
					local rule = {
						ruleTag = e.remarks,
						inboundTag = inbound_tag,
						outboundTag = outbound_tag,
						balancerTag = balancer_tag,
						network = e["network"] or "tcp,udp",
						source = source,
						sourcePort = nil,
						port = e["port"] ~= "" and e["port"] or nil,
						protocol = protocols
					}
					if domains then
						local _rule = api.clone(rule)
						_rule.ruleTag = _rule.ruleTag .. " Domains"
						_rule.domains = domains
						table.insert(rules, _rule)
					end
					if ip then
						local _rule = api.clone(rule)
						_rule.ruleTag = _rule.ruleTag .. " IP"
						_rule.ip = ip
						table.insert(rules, _rule)
					end
					if not domains and not ip and protocols then
						table.insert(rules, rule)
					end
				end
			end)

		--[[
			if default_outbound_tag or default_balancer_tag then
				table.insert(rules, {
					outboundTag = default_outbound_tag,
					balancerTag = default_balancer_tag,
					network = "tcp,udp"
				})
			end
		]]--

			routing = {
				domainStrategy = node.domainStrategy or "AsIs",
				domainMatcher = node.domainMatcher or "hybrid",
				balancers = #balancers > 0 and balancers or nil,
				rules = rules
			}
		elseif node.protocol == "_balancing" then
			if node.balancing_node then
				local balancer_tag = gen_balancer(node)
				if balancer_tag then
					table.insert(rules, { network = "tcp,udp", balancerTag = balancer_tag })
				end
				routing = {
					balancers = balancers,
					rules = rules
				}
				COMMON.default_balancer_tag = balancer_tag
			end
		elseif node.protocol == "_iface" then
			if node.iface then
				local outbound = {
					protocol = "freedom",
					tag = node.remarks or node_id,
					streamSettings = {
						sockopt = {
							mark = 255,
							interface = node.iface
						}
					}
				}
				table.insert(outbounds, outbound)
				COMMON.default_outbound_tag = outbound.tag
				sys.call("touch /tmp/etc/passwall/iface/" .. node.iface)
			end
		else
			local outbound = gen_outbound(flag, node, nil, { fragment = xray_settings.fragment == "1" or nil, noise = xray_settings.fragment == "1" or nil })
			if outbound then
				outbound.tag = outbound.tag .. ":" .. node.remarks
				COMMON.default_outbound_tag = set_outbound_detour(node, outbound, outbounds)
				table.insert(outbounds, outbound)
			end
			routing = {
				domainStrategy = "AsIs",
				domainMatcher = "hybrid",
				rules = {}
			}
		end
	end

	if remote_dns_tcp_server and remote_dns_tcp_port then
		local rules = {}

		if not routing then
			routing = {
				domainStrategy = "IPOnDemand",
				rules = {}
			}
		end

		dns = {
			tag = "dns-in1",
			hosts = {},
			disableCache = (dns_cache and dns_cache == "0") and true or false,
			disableFallback = true,
			disableFallbackIfMatch = true,
			servers = {},
			clientIp = (dns_client_ip and dns_client_ip ~= "") and dns_client_ip or nil,
			queryStrategy = (dns_query_strategy and dns_query_strategy ~= "") and dns_query_strategy or "UseIPv4"
		}

		local _remote_dns = {
			--_flag = "remote",
			address = "tcp://" .. remote_dns_tcp_server,
			port = tonumber(remote_dns_tcp_port)
		}

		local _remote_dns_host
		if remote_dns_doh_url and remote_dns_doh_host then
			if remote_dns_doh_ip and remote_dns_doh_host ~= remote_dns_doh_ip and not api.is_ip(remote_dns_doh_host) then
				dns.hosts[remote_dns_doh_host] = remote_dns_doh_ip
				_remote_dns_host = remote_dns_doh_host
			end
			_remote_dns.address = remote_dns_doh_url
			_remote_dns.port = tonumber(remote_dns_doh_port)
		end

		table.insert(dns.servers, _remote_dns)

	--[[
		local default_dns_flag = "remote"
		if node_id and tcp_redir_port then
			local node = uci:get_all(appname, node_id)
			if node.protocol == "_shunt" then
				if node.default_node == "_direct" then
					default_dns_flag = "direct"
				end
			end
		end

		if dns.servers and #dns.servers > 0 then
			local dns_servers = nil
			for index, value in ipairs(dns.servers) do
				if not dns_servers and value["_flag"] == default_dns_flag then
					dns_servers = {
						_flag = "default",
						address = value.address,
						port = value.port
					}
					break
				end
			end
			if dns_servers then
				table.insert(dns.servers, 1, dns_servers)
			end
		end
	]]--
		local dns_outbound_tag = "direct"
		if dns_socks_address and dns_socks_port then
			dns_outbound_tag = "out"
			table.insert(outbounds, 1, {
				tag = dns_outbound_tag,
				protocol = "socks",
				streamSettings = {
					network = "tcp",
					security = "none",
					sockopt = {
						mark = 255
					}
				},
				settings = {
					servers = {
						{
							address = dns_socks_address,
							port = tonumber(dns_socks_port)
						}
					}
				}
			})
		else
			if COMMON.default_outbound_tag then
				dns_outbound_tag = COMMON.default_outbound_tag
			end
		end

		if dns_listen_port then
			table.insert(inbounds, {
				listen = "127.0.0.1",
				port = tonumber(dns_listen_port),
				protocol = "dokodemo-door",
				tag = "dns-in",
				settings = {
					address = remote_dns_tcp_server,
					port = tonumber(remote_dns_tcp_port),
					network = "tcp,udp"
				}
			})

			table.insert(outbounds, {
				tag = "dns-out",
				protocol = "dns",
				proxySettings = {
					tag = dns_outbound_tag
				},
				settings = {
					address = remote_dns_tcp_server,
					port = tonumber(remote_dns_tcp_port),
					network = "tcp",
					nonIPQuery = "drop"
				}
			})

			table.insert(routing.rules, 1, {
				inboundTag = {
					"dns-in"
				},
				outboundTag = "dns-out"
			})
		end
		table.insert(rules, {
			inboundTag = {
				"dns-in1"
			},
			ip = {
				remote_dns_tcp_server
			},
			port = tonumber(remote_dns_tcp_port),
			outboundTag = dns_outbound_tag
		})
		if _remote_dns_host then
			table.insert(rules, {
				inboundTag = {
					"dns-in1"
				},
				domain = {
					_remote_dns_host
				},
				port = tonumber(remote_dns_doh_port),
				outboundTag = dns_outbound_tag
			})
		end
		if remote_dns_doh_ip then
			table.insert(rules, {
				inboundTag = {
					"dns-in1"
				},
				ip = {
					remote_dns_doh_ip
				},
				port = tonumber(remote_dns_doh_port),
				outboundTag = dns_outbound_tag
			})
		end

		local default_rule_index = #routing.rules > 0 and #routing.rules or 1
		for index, value in ipairs(routing.rules) do
			if value["_flag"] == "default" then
				default_rule_index = index
				break
			end
		end
		for index, value in ipairs(rules) do
			local t = rules[#rules + 1 - index]
			table.insert(routing.rules, default_rule_index, t)
		end

		local dns_hosts_len = 0
		for key, value in pairs(dns.hosts) do
			dns_hosts_len = dns_hosts_len + 1
		end

		if dns_hosts_len == 0 then
			dns.hosts = nil
		end
	end

	if inbounds or outbounds then
		local config = {
			log = {
				-- error = string.format("/tmp/etc/%s/%s.log", appname, node[".name"]),
				loglevel = loglevel
			},
			-- DNS
			dns = dns,
			-- 传入连接
			inbounds = inbounds,
			-- 传出连接
			outbounds = outbounds,
			-- 连接观测
			observatory = observatory,
			-- 路由
			routing = routing,
			-- 本地策略
			policy = {
				levels = {
					[0] = {
						-- handshake = 4,
						-- connIdle = 300,
						-- uplinkOnly = 2,
						-- downlinkOnly = 5,
						bufferSize = xray_settings.buffer_size and tonumber(xray_settings.buffer_size) or nil,
						statsUserUplink = false,
						statsUserDownlink = false
					}
				},
				-- system = {
				--     statsInboundUplink = false,
				--     statsInboundDownlink = false
				-- }
			}
		}

		if xray_settings.fragment == "1" or xray_settings.noise == "1" then
			table.insert(outbounds, {
				protocol = "freedom",
				tag = "dialerproxy",
				settings = {
					domainStrategy = (direct_dns_query_strategy and direct_dns_query_strategy ~= "") and direct_dns_query_strategy or "UseIP",
					fragment = (xray_settings.fragment == "1") and {
						packets = (xray_settings.fragment_packets and xray_settings.fragment_packets ~= "") and xray_settings.fragment_packets,
						length = (xray_settings.fragment_length and xray_settings.fragment_length ~= "") and xray_settings.fragment_length,
						interval = (xray_settings.fragment_interval and xray_settings.fragment_interval ~= "") and xray_settings.fragment_interval
					} or nil,
					noises = (xray_settings.noise == "1") and get_noise_packets() or nil
				},
				streamSettings = {
					sockopt = {
						mark = 255,
						tcpNoDelay = true
					}
				}
			})
		end

		table.insert(outbounds, {
			protocol = "freedom",
			tag = "direct",
			settings = {
				domainStrategy = (dns_query_strategy and dns_query_strategy ~= "") and dns_query_strategy or "UseIPv4"
			},
			streamSettings = {
				sockopt = {
					mark = 255
				}
			}
		})
		table.insert(outbounds, {
			protocol = "blackhole",
			tag = "blackhole"
		})
		for index, value in ipairs(config.outbounds) do
			for k, v in pairs(config.outbounds[index]) do
				if k:find("_") == 1 then
					config.outbounds[index][k] = nil
				end
			end
		end
		return jsonc.stringify(config, 1)
	end
end

function gen_proto_config(var)
	local local_socks_address = var["-local_socks_address"] or "0.0.0.0"
	local local_socks_port = var["-local_socks_port"]
	local local_socks_username = var["-local_socks_username"]
	local local_socks_password = var["-local_socks_password"]
	local local_http_address = var["-local_http_address"] or "0.0.0.0"
	local local_http_port = var["-local_http_port"]
	local local_http_username = var["-local_http_username"]
	local local_http_password = var["-local_http_password"]
	local server_proto = var["-server_proto"]
	local server_address = var["-server_address"]
	local server_port = var["-server_port"]
	local server_username = var["-server_username"]
	local server_password = var["-server_password"]

	local inbounds = {}
	local outbounds = {}
	local routing = nil

	if local_socks_address and local_socks_port then
		local inbound = {
			listen = local_socks_address,
			port = tonumber(local_socks_port),
			protocol = "socks",
			settings = {
				udp = true,
				auth = "noauth"
			}
		}
		if local_socks_username and local_socks_password and local_socks_username ~= "" and local_socks_password ~= "" then
			inbound.settings.auth = "password"
			inbound.settings.accounts = {
				{
					user = local_socks_username,
					pass = local_socks_password
				}
			}
		end
		table.insert(inbounds, inbound)
	end

	if local_http_address and local_http_port then
		local inbound = {
			listen = local_http_address,
			port = tonumber(local_http_port),
			protocol = "http",
			settings = {
				allowTransparent = false
			}
		}
		if local_http_username and local_http_password and local_http_username ~= "" and local_http_password ~= "" then
			inbound.settings.accounts = {
				{
					user = local_http_username,
					pass = local_http_password
				}
			}
		end
		table.insert(inbounds, inbound)
	end

	if server_proto ~= "nil" and server_address ~= "nil" and server_port ~= "nil" then
		local outbound = {
			protocol = server_proto,
			streamSettings = {
				network = "tcp",
				security = "none"
			},
			settings = {
				servers = {
					{
						address = server_address,
						port = tonumber(server_port),
						users = (server_username and server_password) and {
							{
								user = server_username,
								pass = server_password
							}
						} or nil
					}
				}
			}
		}
		if outbound then table.insert(outbounds, outbound) end
	end

	-- 额外传出连接
	table.insert(outbounds, {
		protocol = "freedom", tag = "direct", settings = {keep = ""}, sockopt = {mark = 255}
	})

	local config = {
		log = {
			loglevel = "warning"
		},
		-- 传入连接
		inbounds = inbounds,
		-- 传出连接
		outbounds = outbounds,
		-- 路由
		routing = routing
	}
	return jsonc.stringify(config, 1)
end

_G.gen_config = gen_config
_G.gen_proto_config = gen_proto_config

if arg[1] then
	local func =_G[arg[1]]
	if func then
		print(func(api.get_function_args(arg)))
	end
end
