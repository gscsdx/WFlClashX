// Root hvigor entry. When DevEco Studio generates the ohos/ scaffold via
// `flutter create --platforms ohos`, it writes its own hvigorfile.ts — keep
// the generated version if it differs.
import { appTasks } from '@ohos/hvigor-ohos-plugin';

export default {
  system: appTasks,
  plugins: []
};
