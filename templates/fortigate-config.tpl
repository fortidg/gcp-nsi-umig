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

config system affinity-packet-redistribution
    edit 1
        set interface port1
        set affinity-cpumask 0xFF
    next
    edit 2
        set interface port2
        set affinity-cpumask 0xFF
    next
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
        set distance 5
        set device gcp
    next
    edit 5
        set gateway ${insp_gw}
        set device port1
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
end

config webfilter profile
    edit doc-example-webfilter-profile
        set comment Default web filtering.
        config ftgd-wf
            unset options
            config filters
                edit 1
                    set category 1
                    set action block
                next
                edit 2
                    set category 36
                    set action block
                next
                edit 3
                    set category 37
                    set action block
                next
                edit 4
                    set category 30
                    set action block
                next
                edit 5
                    set category 14
                    set action block
                next
            end
        end
        set log-all-url enable
    next
end

config firewall ssl-ssh-profile
    edit custom-cert
        set comment Read-only SSL handshake inspection profile.
        config https
            set ports 443
            set status certificate-inspection
            set quic bypass
        end
        config ftps
            set status disable
        end
        config imaps
            set status disable
        end
        config pop3s
            set status disable
        end
        config smtps
            set status disable
        end
        config ssh
            set ports 22
            set status disable
        end
        config dot
            set status disable
            set quic inspect
        end
    next
end

config firewall policy
    edit 3
        set name test
        set srcintf gcp
        set dstintf gcp
        set srcaddr all
        set dstaddr all
        set schedule always
        set service PING
        set logtraffic disable
    next
    edit 4
        set name genevepolicy
        set srcintf gcp
        set dstintf gcp
        set action accept
        set srcaddr all
        set dstaddr all
        set schedule always
        set service ALL
        set utm-status enable
        set ssl-ssh-profile custom-cert
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

config system affinity-interrupt
    edit 1
        set interrupt "eth0-ntfy-block.0"
        set affinity-cpumask "0x0000000000000001"
    next
    edit 2
        set interrupt "eth0-ntfy-block.1"
        set affinity-cpumask "0x0000000000000002"
    next
    edit 3
        set interrupt "eth0-ntfy-block.2"
        set affinity-cpumask "0x0000000000000004"
    next
    edit 4
        set interrupt "eth0-ntfy-block.3"
        set affinity-cpumask "0x0000000000000008"
    next
    edit 5
        set interrupt "eth1-ntfy-block.0"
        set affinity-cpumask "0x0000000000000001"
    next
    edit 6
        set interrupt "eth1-ntfy-block.1"
        set affinity-cpumask "0x0000000000000002"
    next
    edit 7
        set interrupt "eth1-ntfy-block.2"
        set affinity-cpumask "0x0000000000000004"
    next
    edit 8
        set interrupt "eth1-ntfy-block.3"
        set affinity-cpumask "0x0000000000000008"
    next
end


%{ if fmg == "true" }
--==FGTCONF==
Content-Type: text/plain; charset="us-ascii"
MIME-Version: 1.0
Content-Transfer-Encoding: 7bit
Content-Disposition: attachment; filename="license"

config system central-management
    set type fortimanager
    set fmg ${fmg_ip}
    set interface-select-method specify
    set interface port2
    set vrf-select 5
end

%{ endif }

--==FGTCONF==

%{ if flx_tok != "" }
--==FGTCONF==
Content-Type: text/plain; charset="us-ascii"
MIME-Version: 1.0
Content-Transfer-Encoding: 7bit
Content-Disposition: attachment; filename="license"

execute vm-license ${flx_tok}

%{ endif }

--==FGTCONF==