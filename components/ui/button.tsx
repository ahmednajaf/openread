import * as React from 'react';
import { cn } from '@/lib/utils';
type Props = React.ButtonHTMLAttributes<HTMLButtonElement> & { variant?: 'glass' | 'quiet' | 'filled'; icon?: boolean };
export function Button({ className, variant = 'glass', icon, type = 'button', ...props }: Props) {
  return <button type={type} className={cn('ui-button inline-flex items-center justify-center gap-2', `button-${variant}`, icon && 'icon-button', className)} {...props} />;
}
