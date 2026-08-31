'use strict';
'require form';
'require network';

// LuCI protocol form for olcRTC.
//
// Registering here is what stops Network -> Interfaces showing "Unsupported
// protocol type" for an olcrtc interface. The Start / Stop / Restart buttons
// come from netifd and need no code on this side.
//
// The API surface is matched against luci-base 26.089 (OpenWrt 25.12):
// getPackageName(), not the older getOpkgPackage().
//
// The shared key is handled as a FILE PATH, never a text field. A value typed
// here would be stored in uci, rendered into LuCI's form state, and included
// in `sysupgrade -b` backups in cleartext.

network.registerPatternVirtual(/^olcrtc[0-9]*$/);

return network.registerProtocol('olcrtc', {
	getI18n() {
		return _('olcRTC Tunnel');
	},

	getIfname() {
		return this._ubus('l3_device') || 'olcrtc0';
	},

	getPackageName() {
		return 'olcrtc';
	},

	// No physical device to pick, and nothing for netifd to wait on.
	isFloating() { return true; },
	isVirtual()  { return true; },
	getDevices() { return null; },

	containsDevice(ifname) {
		return (network.getIfnameOf(ifname) == this.getIfname());
	},

	renderFormOptions(s) {
		var o;

		// ----------------------------------------------------------- link
		o = s.taboption('general', form.ListValue, 'provider',
			_('Provider'),
			_('Conferencing service used for signalling. Jitsi needs no account.'));
		o.value('jitsi', 'Jitsi');
		o.value('telemost', 'Yandex Telemost');
		o.value('wbstream', 'WB Stream');
		o.default = 'jitsi';

		o = s.taboption('general', form.Value, 'room',
			_('Room'),
			_('Full room URL, and it must match the server exactly. Use a long random name: anyone who joins the same room sees your encrypted frames. Note that meet.jit.si requires a token and will not work.'));
		o.placeholder = 'https://meet.example.org/8f3c1d5a9e2b7c4d';
		o.rmempty = false;

		o = s.taboption('general', form.ListValue, 'transport',
			_('Transport'),
			_('How data is carried inside the call. Datachannel is the default; the VP8 and SEI variants disguise traffic as video and may survive stricter filtering.'));
		o.value('datachannel', _('Data channel (SCTP)'));
		o.value('vp8channel', _('VP8 video track'));
		o.value('seichannel', _('H.264 SEI'));
		o.default = 'datachannel';

		o = s.taboption('general', form.Value, 'key_file',
			_('Key file'),
			_('Path to the file holding the 64 hex character shared key, which must match the server. Kept as a file rather than a setting so it is not written into config backups. Must be readable by the olcrtc user: chgrp olcrtc FILE && chmod 0640 FILE'));
		o.default = '/etc/olcrtc/olcrtc.key';
		o.rmempty = false;

		// ------------------------------------------------------- routing
		o = s.taboption('general', form.Flag, 'default_route',
			_('Route all traffic'),
			_('Send all LAN traffic through the tunnel. Turn off to route selectively with a policy-routing package.'));
		o.default = '1';

		// --------------------------------------------------- leak control
		//
		// The tunnel carries TCP over IPv4 only. Turning a toggle off does not
		// make that traffic work -- it makes it leave unencrypted over the WAN.
		o = s.taboption('advanced', form.Flag, 'block_quic',
			_('Block QUIC'),
			_('Reject UDP/443 so browsers fall back to TCP. Disabling this does not tunnel QUIC, it lets QUIC bypass the tunnel in the clear.'));
		o.default = '1';

		o = s.taboption('advanced', form.Flag, 'block_ipv6',
			_('Block IPv6 forwarding'),
			_('The tunnel is IPv4-only. With this off, LAN IPv6 traffic leaves over the WAN unencrypted while the tunnel appears to be up.'));
		o.default = '1';

		o = s.taboption('advanced', form.Flag, 'icmp_reply',
			_('Fake ping replies'),
			_('ICMP cannot traverse this tunnel, so ping normally fails instantly with "Packet filtered". Enabling this makes the local bridge answer pings itself: ping appears to work, but the reply is synthetic and succeeds even for addresses that do not exist, which makes ping useless as a diagnostic. Off by default.'));
		o.default = '0';

		o = s.taboption('advanced', form.Value, 'dns_addr',
			_('DNS resolver'),
			_('Resolver used by olcRTC itself. Must be reachable WITHOUT the tunnel: pointing this at the router\'s local DoH proxy deadlocks bring-up, because that proxy\'s own traffic goes through the tunnel and the tunnel needs DNS to connect. LAN clients are unaffected and still resolve through DoH.'));
		o.default = '1.1.1.1:53';

		o = s.taboption('advanced', form.DynamicList, 'bypass_cidr',
			_('Never route via tunnel'),
			_('Destinations kept on the main routing table. Removing the private ranges can cut off access to this router.'));
		o.datatype = 'cidr4';
		o.placeholder = '192.168.0.0/16';

		o = s.taboption('advanced', form.Value, 'confirm_timeout',
			_('Auto-revert after (s)'),
			_('Safety net for remote administration. If set, the interface takes itself back down after this many seconds unless confirmed with "olcrtc-link --confirm". 0 disables it.'));
		o.datatype = 'uinteger';
		o.default = '0';

		// -------------------------------------------------------- tuning
		o = s.taboption('advanced', form.Value, 'socks_port',
			_('SOCKS5 port'),
			_('Loopback port where olcRTC listens and the TUN bridge connects.'));
		o.datatype = 'port';
		o.default = '8808';

		o = s.taboption('advanced', form.Value, 'tun_addr',
			_('Tunnel address'),
			_('Address of the TUN device. The default is in the benchmarking range and rarely collides.'));
		o.datatype = 'ip4addr';
		o.default = '198.18.0.1';

		o = s.taboption('advanced', form.Value, 'mtu', _('MTU'));
		o.datatype = 'range(576,65535)';
		o.default = '8500';

		o = s.taboption('advanced', form.Value, 'table',
			_('Routing table'),
			_('Table holding the tunnel default route. Kept out of main so the olcRTC daemon\'s own traffic can still reach the conferencing service.'));
		o.datatype = 'uinteger';
		o.default = '8808';

		o = s.taboption('advanced', form.Value, 'metric', _('Route metric'));
		o.datatype = 'uinteger';
		o.default = '10';
	}
});
