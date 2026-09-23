// Copyright 2026 Forkop contributors
// Licensed to the public under the GPL-2.0-or-later.

import { popen } from 'fs';

function action_support_report() {
	let stream = popen(
		'/usr/bin/forkop support_report 2>&1 | /bin/gzip -c',
		'r'
	);

	if (!stream) {
		http.status(500, 'Failed to create support report');
		http.prepare_content('text/plain; charset=UTF-8');
		http.write('Failed to start support report generation\n');
		return;
	}

	http.prepare_content('application/gzip');
	http.header(
		'Content-Disposition',
		'attachment; filename="forkop-support-report.txt.gz"'
	);
	http.header('Cache-Control', 'no-store');

	while (true) {
		let chunk = stream.read(16384);

		if (chunk == null || length(chunk) == 0)
			break;

		http.write(chunk);
	}

	stream.close();
}

return {
	action_support_report
};
