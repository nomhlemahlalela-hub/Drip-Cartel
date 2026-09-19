declare module "https://esm.sh/@supabase/supabase-js@2" {
  export function createClient(...args: unknown[]): any;
}

declare module "https://deno.land/std@0.224.0/crypto/mod.ts" {
  export const crypto: Crypto;
}

declare const Deno: {
  env: {
    get(name: string): string | undefined;
  };
  serve(handler: (request: Request) => Response | Promise<Response>): void;
};
