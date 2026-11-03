import 'package:flutter/material.dart';
import 'package:wormhole/common/common.dart';
import 'package:wormhole/state.dart';
import 'package:wormhole/widgets/widgets.dart';

class AboutView extends StatelessWidget {
  const AboutView({super.key});

  @override
  Widget build(BuildContext context) {
    final items = [
      ListItem(
        title: Text(appLocalizations.project),
        onTap: () {
          globalState.openUrl(
            "https://github.com/gscsdx/WFlClashX",
          );
        },
        trailing: const Icon(Icons.insert_link),
      ),
    ];
    return Padding(
      padding: kMaterialListPadding.copyWith(
        top: 16,
        bottom: 16,
      ),
      child: generateListView(items),
    );
  }
}
