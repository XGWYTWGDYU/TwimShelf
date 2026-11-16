// A control kept across rebuilds of a page (a search field, a text box with what was typed) must
// leave where the last build put it before it goes into the new one: XAML refuses an element that
// is "already the child of another element". The element cannot be asked where it is: once the
// old container has left the tree, Parent and the visual parent both say null. So a build says
// whom it gave the element to (Owned), and the next one takes it back from there (From).
using System.Runtime.CompilerServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace TwimShelf.Controls;

public static class Detach
{
    static readonly ConditionalWeakTable<FrameworkElement, object> Owners = new();

    /// container, noted as the holder of each of the elements.
    public static TOwner Owned<TOwner>(TOwner container, params FrameworkElement[] elements) where TOwner : class
    {
        foreach (var e in elements) Owners.AddOrUpdate(e, container);
        return container;
    }

    public static T From<T>(T e) where T : FrameworkElement
    {
        if (Owners.TryGetValue(e, out var owner))
        {
            Owners.Remove(e);
            switch (owner)
            {
                case Panel p: p.Children.Remove(e); break;
                case ContentControl c when ReferenceEquals(c.Content, e): c.Content = null; break;
                case Border b when ReferenceEquals(b.Child, e): b.Child = null; break;
            }
        }
        return e;
    }
}
