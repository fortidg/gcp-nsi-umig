Content-Type: multipart/mixed; boundary="==FGTCONF=="
MIME-Version: 1.0

--==FGTCONF==
Content-Type: text/plain; charset="us-ascii"
MIME-Version: 1.0
Content-Transfer-Encoding: 7bit
Content-Disposition: attachment; filename="config"

config system global
    set admin-sport ${admin_port}
    set admintimeout 60
end

config system geneve
    edit gcp
        set interface port1
        set type ppp
        set remote-ip ${insp_gw}
    next
end

config system admin
    edit admin
        set password ${admin_pass}
    next
end

config system sdn-connector
    edit gcp
        set type gcp
    next
end

config system interface
    edit port1
        set vdom root
        set mode dhcp
        set allowaccess ping https ssh http probe-response
        set type physical
        set mtu-override enable
        set mtu 1768
    next
    edit port2
        set vdom root
        set vrf 5
        set allowaccess ping https ssh snmp http telnet radius-acct probe-response fabric ftm speed-test
        set type physical
        set mtu-override enable
        set mtu 1460
    next
    edit port1-ilb-probe
        set vdom root
        set ip ${ilb_ip} 255.255.255.255
        set allowaccess probe-response
        set type loopback
        set secondary-IP enable
        config secondaryip
%{ for idx, frontend_ip in frontend_ips ~}
            edit ${idx + 1}
                set ip ${frontend_ip} 255.255.255.255
                set allowaccess probe-response
            next
%{ endfor ~}
        end
    next
    edit gcp
        set vdom root
        set type geneve
        set snmp-index 9
        set interface port1
        set mtu-override enable
        set mtu 1460
        set tcp-mss 1420
    next
end

config system probe-response
    set port ${health_check_port}
    set http-probe-value OK
    set mode http-probe
end

config firewall service custom
    edit ProbeService
        set comment "Default Probe for GCP on port ${health_check_port}"
        set tcp-portrange ${health_check_port}
    next
end

config router static
    edit 1
        set gateway ${mgmt_gw}
        set device port2
    next
    edit 2
        set dst 130.211.0.0 255.255.252.0
        set gateway ${insp_gw}
        set device port1
    next
    edit 3
        set dst 35.191.0.0 255.255.0.0
        set gateway ${insp_gw}
        set device port1
    next
    edit 4
        set dst 10.0.0.0 255.0.0.0
        set distance 5
        set device gcp
    next
    edit 5
        set gateway ${insp_gw}
        set device port1
    next
    edit 6
        set dst 172.16.0.0 255.240.0.0
        set distance 5
        set device gcp
    next
    edit 7
        set dst 192.168.0.0 255.255.0.0
        set distance 5
        set device gcp
    next
end

config router policy
    edit 1
        set input-device port1
        set srcaddr all
        set dstaddr all
        set gateway ${insp_gw}
        set output-device port1
    next
    edit 2
        set input-device gcp
        set srcaddr all
        set dstaddr all
        set output-device gcp
    next
end

# Basic firewall policy for NSI traffic
config firewall policy
    edit 1
        set name Allow-ILB-Probe-Port1
        set srcintf port1
        set dstintf port1-ilb-probe
        set srcaddr all
        set dstaddr all
        set action accept
        set schedule always
        set service ProbeService
    next
    edit 2
        set name nsi-inspection
        set srcintf port1
        set dstintf port1
        set action accept
        set srcaddr all
        set dstaddr all
        set schedule always
        set service ALL
        set inspection-mode flow
        set utm-status enable
    next
    edit 3
        set name genevepolicy
        set srcintf gcp
        set dstintf gcp
        set action accept
        set srcaddr all
        set dstaddr all
        set schedule always
        set service ALL
        set utm-status enable
        set logtraffic all
    next
end

config system fortiguard
    set interface-select-method specify
    set interface port2
    set vrf-select 5
end
config system dns
    set interface-select-method specify
    set interface port2
    set vrf-select 5
end


%{ if fmg == "true" ~}
config system central-management
    set type fortimanager
    set fmg ${fmg_ip}
    set interface-select-method specify
    set interface port2
    set vrf-select 5
end
%{ endif ~}
%{ if flx_tok != "" ~}
--==FGTCONF==
Content-Type: text/plain; charset="us-ascii"
MIME-Version: 1.0
Content-Transfer-Encoding: 7bit
Content-Disposition: attachment; filename="license"

LICENSE-TOKEN:${trimprefix(flx_tok, "LICENSE-TOKEN:")}
%{ endif ~}
--==FGTCONF==--