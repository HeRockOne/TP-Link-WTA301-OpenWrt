'use strict';

// WTA301 概览页 section：CPU 使用率 + 全部温度传感器（排在「系统」与「内存」之间）。
//
// 为什么叫 15_：
//   LuCI 的 view/status/index.js 会 lsdir('view/status/include')，
//   把目录里每个 *.js 按文件名字符串排序后 require —— 自动出现，
//   不用改任何上游文件。数字前缀 = 页面顺序（10_system < 15 < 20_memory）。
//
// CPU 使用率靠两次轮询差分（LuCI 默认 5 秒），首次渲染显示「采样中」。

'require baseclass';
'require rpc';

var callStatus = rpc.declare({ object: 'wta301', method: 'status' });

function celsius(mC) {
	return (mC == null) ? '?' : '%.1f °C'.format(mC / 1000);
}

function tempColor(mC, trip) {
	if (mC == null)
		return null;
	if (trip != null && mC >= trip)
		return '#d9534f';
	if (mC >= 75000)
		return '#f0ad4e';
	return '#5cb85c';
}

function bar(pct) {
	if (pct == null)
		return _('采样中…');

	var color = (pct >= 90) ? '#d9534f' : (pct >= 60) ? '#f0ad4e' : '#5cb85c';

	// 必须限定宽度且 inline-block，否则 cbi-progressbar 是 block，
	// 会占满整行并把后面的百分比挤到下一行。
	return E('div', {
		'class': 'cbi-progressbar',
		'style': 'width:200px;display:inline-block;vertical-align:middle;margin:0',
		'title': '%d%%'.format(pct)
	}, E('div', { 'style': 'width:%d%%;background:%s'.format(pct, color) }));
}

function row(label, value, color) {
	var cell = E('td', { 'class': 'td left' }, [ value ]);

	if (color)
		cell.style.color = color;
	if (color)
		cell.style.fontWeight = 'bold';

	return E('tr', { 'class': 'tr' }, [
		E('td', { 'class': 'td left', 'width': '30%' }, [ label ]),
		cell
	]);
}

return baseclass.extend({
	title: _('CPU 使用率与温度'),

	// 上一次轮询的 /proc/stat 累计值（毫秒级精度不需要，5 秒窗口足够）
	_prev: null,

	load: function() {
		var self = this;

		return L.resolveDefault(callStatus(), {}).then(function(st) {
			var cpu = st.cpu || {}, pct = null;

			if (self._prev && cpu.total != null && self._prev.total != null) {
				var dt = cpu.total - self._prev.total;
				var di = cpu.idle - self._prev.idle;

				if (dt > 0)
					pct = Math.max(0, Math.min(100, Math.round(100 * (dt - di) / dt)));
			}

			self._prev = { total: cpu.total, idle: cpu.idle };

			return {
				pct: pct,
				ncpu: st.ncpu || 1,
				thermal: st.thermal || [],
				radio: st.radio || []
			};
		});
	},

	render: function(d) {
		var table = E('table', { 'class': 'table' }),
		    byName = {}, others = [], i, r;

		for (i = 0; i < d.thermal.length; i++)
			byName[d.thermal[i].name] = d.thermal[i];

		var cpuT = byName['cpu-thermal'] || null;

		table.appendChild(row(
			_('CPU 使用率'),
			E('span', { 'style': 'white-space:nowrap' }, [
				bar(d.pct),
				(d.pct == null) ? '' : ' %d%%（%d 核）'.format(d.pct, d.ncpu)
			])
		));

		table.appendChild(row(
			_('CPU 温度'),
			cpuT
				? celsius(cpuT.mC) + (cpuT.trip_mC ? _('，降频点 %s').format(celsius(cpuT.trip_mC)) : '')
				: _('无传感器'),
			cpuT ? tempColor(cpuT.mC, cpuT.trip_mC) : null
		));

		for (i = 0; i < d.radio.length; i++) {
			r = d.radio[i];

			table.appendChild(row(
				(r.phy == 'phy0') ? _('2.4G 射频') : (r.phy == 'phy1') ? _('5G 射频') : r.phy,
				celsius(r.mC),
				tempColor(r.mC, 95000)
			));
		}

		for (i = 0; i < d.thermal.length; i++)
			if (d.thermal[i].name != 'cpu-thermal')
				others.push('%s %s'.format(d.thermal[i].name, celsius(d.thermal[i].mC)));

		if (others.length)
			table.appendChild(row(_('其它传感器'), others.join(' · ')));

		return table;
	}
});

