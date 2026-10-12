import UIKit

/// Keeps the edge swipe-back gesture working on screens that hide the
/// navigation bar (the chat screen uses its own header notch).
///
/// UIKit turns the interactive pop gesture off when the bar is hidden; giving
/// it a delegate that allows it whenever there is something to pop back to
/// turns it on again.
extension UINavigationController: UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }
}
