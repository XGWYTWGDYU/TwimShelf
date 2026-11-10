// The web build has no mascot pet (it walks the desktop over the window; a page has no desktop).
class PetEngine {
  PetEngine(int seed);
  void dispose() {}
  void setBounds(double width, double height, double marginRight, double marginBottom) {}
  void pointer(double x, double y) {}
  void pointerGone() {}
  bool hit(double x, double y) => false;
  bool tap(double x, double y) => false;
  List<double> tick(double seconds) => const [];
}
