import { createFileRoute, redirect } from "@tanstack/react-router";
import { Shield } from "lucide-react";

import { fetchSession } from "@/lib/session-fns";
import { GoogleAdminSignInButton } from "@/components/admin/google-admin-sign-in-button";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";

export const Route = createFileRoute("/login")({
  beforeLoad: async () => {
    const session = await fetchSession();
    if (session && session.user.role === "admin") {
      throw redirect({ to: "/users" });
    }
  },
  component: AdminLoginPage,
  head: () => ({
    meta: [{ title: "Admin Login — CaptureCat" }],
  }),
});

function AdminLoginPage() {
  return (
    <main className="mx-auto flex min-h-screen w-full max-w-md items-center px-6">
      <Card className="w-full">
        <CardHeader className="space-y-3">
          <div className="inline-flex size-10 items-center justify-center rounded-full bg-primary/10 text-primary">
            <Shield className="size-5" />
          </div>
          <CardTitle>Admin Access</CardTitle>
          <CardDescription>
            Sign in with an account whose role is <code>admin</code>. Roles are
            managed by Better Auth; anyone else is redirected away.
          </CardDescription>
        </CardHeader>
        <CardContent>
          <GoogleAdminSignInButton />
        </CardContent>
      </Card>
    </main>
  );
}
