// The search capsule: words match tags, post text and authors; Enter searches, Esc clears.
import { useEffect, useState } from 'react';
import { Search, X } from 'lucide-react';
import { L } from '@twimshelf/core';
import './SearchBar.css';

export function SearchBar({ value, onSearch }: { value: string; onSearch: (q: string) => void }) {
  const [text, setText] = useState(value);
  useEffect(() => setText(value), [value]);
  return (
    <div className="search">
      <Search size={15} className="search-icon" />
      <input value={text} placeholder={L('search.placeholder')} onChange={(e) => setText(e.target.value)}
        onKeyDown={(e) => {
          if (e.nativeEvent.isComposing) return;
          if (e.key === 'Enter') onSearch(text.trim());
          if (e.key === 'Escape') { setText(''); onSearch(''); }
        }} />
      {text && <button className="search-clear" onClick={() => { setText(''); onSearch(''); }} aria-label={L('common.clear')}><X size={13} /></button>}
    </div>
  );
}
