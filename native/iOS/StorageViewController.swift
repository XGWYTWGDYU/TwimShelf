import SwiftUI
import UIKit

/// 设置 → 存储空间: the shared page. Its heading says what it is, so the bar stays empty.
final class StorageViewController: UIHostingController<AnyView> {
    init() {
        super.init(rootView: AnyView(EmptyView()))
        rootView = AnyView(
            ScrollView {
                StorageUsageView(showsTitle: true) { [weak self] in
                    self?.navigationController?.pushViewController(ModelsViewController(), animated: true)
                }
                .padding(.horizontal, 16).padding(.bottom, 24)
            }
            .background(Color(uiColor: .systemGroupedBackground))
        )
        navigationItem.largeTitleDisplayMode = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
