import { IDiagnosticsChecksStoreItem, store } from '../../../services';
import { formatCoreLabel } from '../../../helpers/singBoxVariant';

export function updateCheckStore(
  check: IDiagnosticsChecksStoreItem,
  minified?: boolean,
) {
  const core = store.get().diagnosticsSystemInfo;
  check = {
    ...check,
    title: formatCoreLabel(check.title, core),
    items: check.items.map((item) => ({
      ...item,
      key: formatCoreLabel(item.key, core),
    })),
  };
  const diagnosticsChecks = store.get().diagnosticsChecks;
  const other = diagnosticsChecks.filter((item) => item.code !== check.code);

  const smallCheck: IDiagnosticsChecksStoreItem = {
    ...check,
    items: check.items.filter((item) => item.state !== 'success'),
  };

  const targetCheck = minified ? smallCheck : check;

  store.set({
    diagnosticsChecks: [...other, targetCheck],
  });
}
