'use strict';
'require form';
'require network';

// LuCI protocol form for olcRTC.
//
// Registering the protocol here is what gives the interface an Edit form under
// Network -> Interfaces. The Start / Stop / Restart buttons come from netifd
// and need no code on this side.
//
// The shared key is handled as a FILE PATH, never a text field: a value typed
// here would be stored in uci, rendered into LuCI's form state, and included
// in `sysupgrade -b` backups in cleartext.

network.registerPatternVirtual(/^olcrtc-.+$/);

return network.registerProtocol('olcrtc', {
	getI18n: function() {
		return _('olcRTC Tunnel');
	},

	getIfname: function() {
		return this._ubus('l3_device') || 'olcrtc0';
	},

	getOpkgPackage: function() {
		return 'olcrtc';
	},

	// No physical device to pick, and nothing for netifd to wait on.
	isFloating: function() { return true; },
	isVirtual:  function() { return true; },

	getDevices: function() { return null; },
	containsDevice: function(ifname) {
		return (network.getIfnameOf(ifname) == this.getIfname());
	},

	renderFormOptions: function(s) {
		var o;

		// ---------------------------------------------------------- link
		o = s.taboption('general', form.ListValue, 'provider',
			_('Provider'),
			_('Conferencing service used for signalling. Jitsi needs no account.'));
		o.value('jitsi', 'Jitsi');
		o.value('telemost', 'Yandex Telemost');
		o.value('wbstream', 'WB Stream');
		o.default = 'jitsi';

		o = s.taboption('general', form.Value, 'room',
			_('Room'),
			_('Full room URL. Must match the server exactly. Use a long random name — anyone who joins the same room sees your encrypted frames.'));
		o.placeholder = 'https://meet.example.org/8f3c1d5a9e2b7c4d';
		o.rmempty = false;

		o = s.taboption('general', form.ListValue, 'transport',
			_('Transport'),
			_('How data is carried inside the call. Datachannel is the default; the VP8 variants disguise traffic as video and may survive stricter filtering.'));
		o.value('datachannel', _('Data channel (SCTP)'));
		o.value('vp8channel', _('VP8 video track'));
		o.value('seichannel', _('H.264 SEI'));
		o.default = 'datachannel';

		o = s.taboption('general', form.Value, 'key_file',
			_('Key file'),
			_('Path to the file holding the 64 hex character shared key. Must match the server. Stored as a file rather than here so it is not written into config backups.'));
		o.default = '/etc/olcrtc/olcrtc.key';
		o.rmempty = false;

		// ------------------------------------------------------ leak control
		//
		// These are the fail-closed defaults. The tunnel carries TCP over IPv4
		// only; disabling a toggle does not make that traffic work, it makes
		// it leave unencrypted over the WAN instead.
		o = s.taboption('advanced', form.Flag, 'block_quic',
			_('Block QUIC'),
			_('Reject UDP/443 so browsers fall back to TCP. Disabling this does not tunnel QUIC — it lets it bypass the tunnel in the clear.'));
		o.default = '1';

		o = s.taboption('advanced', form.Flag, 'block_ipv6',
			_('Block IPv6 forwarding'),
			_('The tunnel is IPv4-only. With this off, LAN IPv6 traffic exits over the WAN unencrypted while the tunnel appears to be up.'));
		o.default = '1';

		o = s.taboption('advanced', form.Flag, 'default_route',
			_('Route all traffic'),
			_('Send all LAN traffic through the tunnel. Turn off to route selectively with a policy-routing package.'));
		o.default = '1';

		o = s.taboption('advanced', form.Value, 'dns_addr',
			_('DNS resolver'),
			_('Where olcRTC resolves names. Defaults to the local https-dns-proxy, which resolves over TCP/443 through the tunnel — plain UDP DNS cannot traverse it.'));
		o.default = '127.0.0.1:5053';

		// ---------------------------------------------------------- tuning
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
		o.datatype = 'range(576, 65535)';
		o.default = '8500';

		o = s.taboption('advanced', form.Value, 'metric', _('Route metric'));
		o.datatype = 'uinteger';
		o.default = '10';
	}
});
