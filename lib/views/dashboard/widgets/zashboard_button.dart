import 'package:wormhole/common/common.dart';
import 'package:wormhole/providers/config.dart';
import 'package:wormhole/views/zashboard.dart';
import 'package:wormhole/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ZashboardButton extends ConsumerWidget {
  const ZashboardButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final inApp = ref.watch(
      appSettingProvider.select((state) => state.zashboardInApp),
    );
    return SizedBox(
      height: getWidgetHeight(1),
      child: CommonCard(
        onPressed: () {
          openZashboard(context, inApp: inApp);
        },
        info: const Info(
          label: 'zashboard',
          iconData: Icons.space_dashboard_outlined,
        ),
        child: Container(
          padding: baseInfoEdgeInsets.copyWith(
            top: 4,
            bottom: 8,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.max,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                flex: 1,
                child: TooltipText(
                  text: Text(
                    appLocalizations.openPanel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.adjustSize(-2)
                        .toLight,
                  ),
                ),
              ),
              Icon(
                Icons.open_in_new,
                size: 20,
                color: context.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
