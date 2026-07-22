/** The Nib pen glyph (monochrome, inherits text color). Same artwork as the
 *  menu-bar icon (Sources/loco/Resources). */
export function NibGlyph({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 24 24" fill="none" aria-hidden className={className}>
      <g transform="rotate(20 12 12)">
        <rect
          x="8.3"
          y="2.6"
          width="7.4"
          height="1.8"
          rx="0.7"
          fill="currentColor"
        />
        <path
          fillRule="evenodd"
          clipRule="evenodd"
          d="M8.7 4.9L15.3 4.9C16.6 5.8 17.4 7.3 17.4 9.1C17.4 13.1 14.6 16.6 12 21.4C9.4 16.6 6.6 13.1 6.6 9.1C6.6 7.3 7.4 5.8 8.7 4.9ZM11.66 4.9L12.34 4.9L12.34 8.85L11.66 8.85L11.66 4.9ZM12 8.6C12.9 8.6 13.6 9.42 13.6 10.5C13.6 11.58 12.9 12.4 12 12.4C11.1 12.4 10.4 11.58 10.4 10.5C10.4 9.42 11.1 8.6 12 8.6ZM11.42 12.55L12.58 12.55L12 19.9L11.42 12.55Z"
          fill="currentColor"
        />
      </g>
    </svg>
  );
}
