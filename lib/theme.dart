import 'package:flutter/material.dart';

/// RuView-inspired observatory theme: near-black background, floating
/// glass panels, monospace technical type, glowing accents.
/// Dark only — there is intentionally no light theme.

class OutrideColors {
  static const background = Color(0xFF060809); // near-black
  static const surface = Color(0xFF0B0F14); // floating panel
  static const surface2 = Color(0xFF121822); // inputs, wells
  static const border = Color(0xFF1E2A36); // hairline panel borders

  static const green = Color(0xFF4ADE80); // ok / present / clear
  static const red = Color(0xFFF87171); // alert values
  static const amber = Color(0xFFFBBF24); // warning / detected
  static const orange = Color(0xFFFB923C); // accent
  static const blue = Color(0xFF60A5FA); // signal values / links
  static const cyan = Color(0xFF22D3EE); // legacy accent (kept for compat)
  static const purple = Color(0xFFA78BFA); // scan actions
  static const muted = Color(0xFF8A94A6); // secondary labels

  static const onDark = Color(0xFFE8EEF4); // primary text
}

/// Monospace technical typography, RuView style.
class OutrideType {
  static const String mono = 'JetBrainsMono';

  /// Letterspaced section header, e.g. "VITAL SIGNS".
  static TextStyle section([double size = 11]) => TextStyle(
        fontFamily: mono,
        fontSize: size,
        letterSpacing: 2.4,
        color: OutrideColors.muted,
        fontWeight: FontWeight.w500,
      );

  /// Big numeric readout, e.g. "121".
  static TextStyle readout(double size, Color color) => TextStyle(
        fontFamily: mono,
        fontSize: size,
        fontWeight: FontWeight.w700,
        color: color,
        letterSpacing: 0.5,
      );

  static TextStyle rowLabel() => const TextStyle(
        fontFamily: mono,
        fontSize: 12,
        color: OutrideColors.muted,
        letterSpacing: 0.8,
      );

  static TextStyle rowValue(Color color) => TextStyle(
        fontFamily: mono,
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: color,
      );

  static TextStyle chip(Color color) => TextStyle(
        fontFamily: mono,
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.6,
        color: color,
      );
}

/// Floating dark panel with a hairline border, RuView style.
class OutridePanel extends StatelessWidget {
  const OutridePanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.glow,
  });

  final Widget child;
  final EdgeInsets padding;

  /// Optional accent glow: tints the border and casts a soft outer
  /// shadow. Used for alert states (amber DETECTED, green CLEAR).
  final Color? glow;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: OutrideColors.surface,
        border: Border.all(color: glow ?? OutrideColors.border),
        borderRadius: BorderRadius.circular(16),
        boxShadow: glow == null
            ? null
            : [
                BoxShadow(
                  color: glow!.withAlpha(50),
                  blurRadius: 28,
                  spreadRadius: 1,
                ),
              ],
      ),
      padding: padding,
      child: child,
    );
  }
}

/// Outlined pill chip, e.g. "INBOUND", "SIZE M".
class OutrideChip extends StatelessWidget {
  const OutrideChip({
    super.key,
    required this.label,
    required this.color,
    this.icon,
  });

  final String label;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding:
          const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withAlpha(24),
        border: Border.all(color: color.withAlpha(160)),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, color: color, size: 14),
            const SizedBox(width: 6),
          ],
          Text(label, style: OutrideType.chip(color)),
        ],
      ),
    );
  }
}

/// The one button style in the app: transparent purple, never a solid
/// block. A translucent Outride purple (#A78BFA, ~12% opacity) fill
/// over the dark background, purple text, hairline purple border.
/// Draco's call: buttons read purple but none is a solid block.
/// The global [ElevatedButton] theme below uses [primary], so every
/// primary action in the app — START/STOP included — gets this style
/// with no per-screen styling. [outline] is the border-only sibling
/// for secondary actions (mute, hunt).
class OutrideButtons {
  static ButtonStyle get primary => ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.disabled)
                ? OutrideColors.muted.withAlpha(16)
                : OutrideColors.purple.withAlpha(31)),
        foregroundColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.disabled)
                ? OutrideColors.muted
                : OutrideColors.purple),
        side: WidgetStateProperty.resolveWith((states) => BorderSide(
            color: states.contains(WidgetState.disabled)
                ? OutrideColors.muted.withAlpha(60)
                : OutrideColors.purple.withAlpha(110))),
        shape: WidgetStateProperty.all(RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20))),
        padding: WidgetStateProperty.all(
            const EdgeInsets.symmetric(horizontal: 22, vertical: 12)),
        textStyle: WidgetStateProperty.all(const TextStyle(
          fontFamily: OutrideType.mono,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.5,
          fontSize: 13,
        )),
      );

  /// Border-only sibling of [primary]: same purple text and hairline
  /// border, fully transparent fill.
  static ButtonStyle get outline => ButtonStyle(
        backgroundColor:
            WidgetStateProperty.all(Colors.transparent),
        foregroundColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.disabled)
                ? OutrideColors.muted
                : OutrideColors.purple),
        side: WidgetStateProperty.resolveWith((states) => BorderSide(
            color: states.contains(WidgetState.disabled)
                ? OutrideColors.muted.withAlpha(60)
                : OutrideColors.purple.withAlpha(110))),
        shape: WidgetStateProperty.all(RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20))),
        padding: WidgetStateProperty.all(
            const EdgeInsets.symmetric(horizontal: 22, vertical: 12)),
        textStyle: WidgetStateProperty.all(const TextStyle(
          fontFamily: OutrideType.mono,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.5,
          fontSize: 13,
        )),
      );
}

/// Small floating + / − / 1:1 zoom controls for the 3D views.
class OutrideZoomControls extends StatelessWidget {
  const OutrideZoomControls({
    super.key,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onReset,
  });

  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: OutrideColors.surface.withAlpha(220),
        border: Border.all(color: OutrideColors.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _btn('+', onZoomIn),
          _btn('−', onZoomOut),
          _btn('1:1', onReset),
        ],
      ),
    );
  }

  Widget _btn(String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Text(label, style: OutrideType.chip(OutrideColors.onDark)),
      ),
    );
  }
}

ThemeData buildDarkTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  return base.copyWith(
    colorScheme: const ColorScheme.dark(
      primary: OutrideColors.blue,
      secondary: OutrideColors.amber,
      surface: OutrideColors.surface,
      error: OutrideColors.red,
      onPrimary: Colors.black,
      onSecondary: Colors.black,
      onSurface: OutrideColors.onDark,
    ),
    scaffoldBackgroundColor: OutrideColors.background,
    cardColor: OutrideColors.surface,
    dividerColor: OutrideColors.border,
    appBarTheme: AppBarTheme(
      backgroundColor: OutrideColors.background,
      foregroundColor: OutrideColors.onDark,
      elevation: 0,
      titleTextStyle: OutrideType.section(15).copyWith(
        color: OutrideColors.onDark,
        letterSpacing: 4,
        fontWeight: FontWeight.w700,
      ),
    ),
    bottomNavigationBarTheme: const BottomNavigationBarThemeData(
      backgroundColor: Color(0xFF080B0E),
      selectedItemColor: OutrideColors.green,
      unselectedItemColor: OutrideColors.muted,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? OutrideColors.green : OutrideColors.muted,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected)
            ? OutrideColors.green.withAlpha(90)
            : OutrideColors.surface2,
      ),
    ),
    sliderTheme: base.sliderTheme.copyWith(
      activeTrackColor: OutrideColors.blue,
      inactiveTrackColor: OutrideColors.surface2,
      thumbColor: OutrideColors.blue,
      overlayColor: OutrideColors.blue.withAlpha(40),
      valueIndicatorColor: OutrideColors.surface2,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: OutrideColors.surface2,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: OutrideColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: OutrideColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: OutrideColors.blue),
      ),
      labelStyle: const TextStyle(
          color: OutrideColors.muted, fontFamily: OutrideType.mono, fontSize: 12),
      hintStyle: const TextStyle(
          color: OutrideColors.muted, fontFamily: OutrideType.mono, fontSize: 12),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      // One style for every primary action: transparent purple, never
      // a solid block (see OutrideButtons).
      style: OutrideButtons.primary,
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: OutrideColors.blue,
        textStyle: const TextStyle(
          fontFamily: OutrideType.mono,
          fontSize: 12,
          letterSpacing: 1.2,
        ),
      ),
    ),
    textTheme: base.textTheme.apply(
      bodyColor: OutrideColors.onDark,
      displayColor: OutrideColors.onDark,
    ),
  );
}
